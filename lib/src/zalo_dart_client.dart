import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart';

import 'zalo_curl_interceptor.dart';
import 'zalo_logger.dart';
import 'zalo_models.dart';
import 'zalo_qr_login_service.dart';

class ZaloDartClient {
  ZaloDartClient({
    required ZaloCredentials credentials,
    Dio? client,
    int? firstLaunchTime,
    String Function(int? minLength, int? maxLength)? randomStringBuilder,
    ZaloSocketConnector? socketConnector,
    Future<void> Function()? onSessionExpired,
    Future<void> Function(ZaloSessionEndReason reason)? onSessionInvalidated,
  }) : _credentials = credentials,
       _firstLaunchTime =
           firstLaunchTime ?? DateTime.now().millisecondsSinceEpoch,
       _randomStringBuilder = randomStringBuilder ?? _defaultRandomString,
       _socketConnector = socketConnector ?? _defaultSocketConnector,
       _onSessionExpired = onSessionExpired,
       _onSessionInvalidated = onSessionInvalidated,
       _client = _buildHttpClient(client);

  ZaloDartClient.fromSnapshot(
    ZaloConnectionSnapshot snapshot, {
    Dio? client,
    String Function(int? minLength, int? maxLength)? randomStringBuilder,
    ZaloSocketConnector? socketConnector,
    Future<void> Function()? onSessionExpired,
    Future<void> Function(ZaloSessionEndReason reason)? onSessionInvalidated,
  }) : _credentials = snapshot.credentials,
       _firstLaunchTime = DateTime.now().millisecondsSinceEpoch,
       _randomStringBuilder = randomStringBuilder ?? _defaultRandomString,
       _socketConnector = socketConnector ?? _defaultSocketConnector,
       _onSessionExpired = onSessionExpired,
       _onSessionInvalidated = onSessionInvalidated,
       _client = _buildHttpClient(client),
       _uid = snapshot.session.userId,
       _secretKey = snapshot.session.secretKey,
       _serviceMap = snapshot.session.serviceMap,
       _wsUrls = snapshot.session.wsUrls,
       _settings = snapshot.session.settings,
       _extraVersions = snapshot.session.extraVersions;

  static const _apiType = 30;
  // zpw_ver: phải khớp API version hiện hành của Zalo Web. Bump 671 -> 685 theo
  // zca-js PR #327 — version cũ bị server từ chối gây lỗi session/đăng nhập.
  static const _apiVersion = 685;
  static const _language = 'vi';
  static const _computerName = 'Web';
  static const _chatOrigin = 'https://chat.zalo.me';
  static const _checkSessionUrl =
      'https://id.zalo.me/account/checksession'
      '?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html';
  static const _userInfoUrl = 'https://jr.chat.zalo.me/jr/userinfo';
  static const _loginInfoUrl =
      'https://wpa.chat.zalo.me/api/login/getLoginInfo';
  static const _serverInfoUrl =
      'https://wpa.chat.zalo.me/api/login/getServerInfo';
  static const _manualCloseCode = 1000;
  static const _abnormalCloseCode = 1006;
  static const _duplicateConnectionCloseCode = 3000;
  static const _kickConnectionCloseCode = 3003;
  // App-specific close code we send when the liveness watchdog force-closes a
  // silently dead (half-open) socket. Must sit in the 3000-4999 app range that
  // dart:io allows us to send, and must NOT collide with the session
  // invalidation codes (3000/3003) which route to re-login instead of retry.
  static const _livenessCloseCode = 4001;
  // A connect attempt that never resolves would otherwise pin
  // `_isConnectingListener = true` forever and block every future reconnect.
  static const _connectTimeout = Duration(seconds: 20);
  static const _logName = 'PAM.ZaloClient';

  final Dio _client;
  final ZaloCredentials _credentials;
  final int _firstLaunchTime;
  final String Function(int? minLength, int? maxLength) _randomStringBuilder;
  final ZaloSocketConnector _socketConnector;
  final Future<void> Function()? _onSessionExpired;
  final Future<void> Function(ZaloSessionEndReason reason)? _onSessionInvalidated;

  String? _uid;
  String? _secretKey;
  Map<String, List<String>> _serviceMap = const {};
  List<String> _wsUrls = const [];
  Map<String, dynamic> _settings = const {};
  Map<String, dynamic> _extraVersions = const {};
  StreamController<ZaloMessage>? _messageController;
  StreamSubscription<dynamic>? _listenerSubscription;
  ZaloWebSocketConnection? _listenerSocket;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  Timer? _livenessTimer;
  String? _cipherKey;
  int _wsMessageId = 0;
  int _currentWsIndex = 0;
  bool _manualListenerStop = false;
  bool _retryListenerOnClose = true;
  bool _isConnectingListener = false;
  bool _isHandlingSessionExpiry = false;
  bool _isHandlingSessionInvalidation = false;
  final Map<int, int> _listenerRetryCounts = <int, int>{};

  bool get isInitialized => _secretKey != null && _secretKey!.isNotEmpty;

  static Dio _buildHttpClient(Dio? client) {
    if (client != null) {
      return client;
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 20),
        responseType: ResponseType.plain,
        followRedirects: false,
        validateStatus: (_) => true,
      ),
    );
    if (kDebugMode) {
      dio.interceptors.add(ZaloCurlLoggingInterceptor());
    }

    return dio;
  }

  ZaloSessionInfo? get sessionInfo {
    final uid = _uid;
    final secretKey = _secretKey;
    if (uid == null || uid.isEmpty || secretKey == null || secretKey.isEmpty) {
      return null;
    }

    return ZaloSessionInfo(
      userId: uid,
      secretKey: secretKey,
      serviceMap: _serviceMap,
      wsUrls: _wsUrls,
      settings: _settings,
      extraVersions: _extraVersions,
    );
  }

  Future<ZaloProfile> initSession() async {
    zaloLog(
      'Initializing Zalo runtime session',
      name: _logName,
      data: {
        'cookieBytes': _credentials.cookie.length,
        'imei': maskValue(_credentials.imei, head: 8, tail: 8),
      },
    );

    final loginData = await _callLoginApi();

    final uid = loginData['uid'] as String?;
    final secretKey = loginData['zpw_enk'] as String?;
    final serviceMap = _parseServiceMap(loginData['zpw_service_map_v3']);
    final wsUrls = _asStringList(loginData['zpw_ws']);

    if (uid == null || uid.isEmpty) {
      throw const ZaloLoginException(
        'Zalo không trả về user id để khởi tạo phiên.',
      );
    }
    if (secretKey == null || secretKey.isEmpty) {
      throw const ZaloLoginException(
        'Zalo không trả về khóa mã hóa cho phiên hiện tại.',
      );
    }
    if (serviceMap.isEmpty) {
      throw const ZaloLoginException(
        'Zalo không trả về service map để tiếp tục runtime.',
      );
    }

    _uid = uid;
    _secretKey = secretKey;
    _serviceMap = serviceMap;
    _wsUrls = wsUrls;
    zaloLog(
      'Loaded Zalo login info',
      name: _logName,
      data: {
        'uid': maskValue(uid, head: 3, tail: 3),
        'services': serviceMap.keys.toList(growable: false),
        'wsCount': wsUrls.length,
      },
    );

    final serverInfo = await _callGetServerInfo();
    _settings = _asMap(serverInfo['settings'] ?? serverInfo['setttings']);
    _extraVersions = _asMap(serverInfo['extra_ver']);
    zaloLog(
      'Loaded Zalo server info',
      name: _logName,
      data: {'extraVersions': _extraVersions.keys.toList(growable: false)},
    );

    final profile = await getAccountInfo();
    zaloLog(
      'Initialized Zalo runtime session',
      name: _logName,
      data: {'profile': profile.displayName},
    );
    return profile;
  }

  Future<ZaloProfile> getAccountInfo() async {
    if (!isInitialized) {
      return _getLegacyAccountInfo();
    }

    final profileEndpoint = _serviceEndpoint('profile');
    final response = await _get(
      _makeUrl('$profileEndpoint/api/social/profile/me-v2'),
    );
    final data = _resolveResponseData(response);
    return ZaloProfile.fromProfileJson(_asMap(data));
  }

  Stream<ZaloMessage> startListener({bool retryOnClose = true}) {
    if (_wsUrls.isEmpty) {
      throw const ZaloLoginException(
        'Zalo chưa cung cấp endpoint realtime cho listener.',
      );
    }

    _retryListenerOnClose = retryOnClose;
    _manualListenerStop = false;
    final controller = _messageController ??=
        StreamController<ZaloMessage>.broadcast(
          onCancel: () async {
            if (!(_messageController?.hasListener ?? false)) {
              await stopListener(closeStream: false);
            }
          },
        );

    if (_listenerSocket == null && !_isConnectingListener) {
      zaloLog(
        'Starting realtime listener',
        name: _logName,
        data: {
          'wsUrlCount': _wsUrls.length,
          'currentWsIndex': _currentWsIndex,
          'retryOnClose': retryOnClose,
        },
      );
      unawaited(_connectListener());
    }

    return controller.stream;
  }

  Future<void> stopListener({bool closeStream = true}) async {
    _manualListenerStop = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _cipherKey = null;
    _wsMessageId = 0;

    await _listenerSubscription?.cancel();
    _listenerSubscription = null;

    final socket = _listenerSocket;
    _listenerSocket = null;
    if (socket != null) {
      await socket.close(_manualCloseCode, 'manual');
    }

    if (closeStream) {
      await _messageController?.close();
      _messageController = null;
    }
  }

  Future<void> reconnectListenerNow() async {
    final controller = _messageController;
    if (controller == null || controller.isClosed || _manualListenerStop) {
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    if (_listenerSocket != null || _isConnectingListener) {
      return;
    }

    await _connectListener();
  }

  void requestOldMessages({
    required ZaloThreadType threadType,
    String? lastMessageId,
  }) {
    _sendRealtimeFrame(
      version: 1,
      cmd: threadType == ZaloThreadType.user ? 510 : 511,
      subCmd: 1,
      data: {
        'first': true,
        'lastId': lastMessageId,
        'preIds': const <String>[],
      },
    );
  }

  Future<ZaloSendResult> sendMessage({
    required String content,
    required String threadId,
    required ZaloThreadType threadType,
    ZaloQuote? quote,
  }) async {
    final trimmedContent = content.trim();
    if (trimmedContent.isEmpty) {
      throw const ZaloLoginException('Nội dung tin nhắn không được để trống.');
    }

    if (threadId.trim().isEmpty) {
      throw const ZaloLoginException('Thiếu thread id để gửi tin nhắn.');
    }

    if (quote != null &&
        quote.content != null &&
        quote.content is! String &&
        quote.msgType == 'webchat') {
      throw const ZaloLoginException(
        'Hiện chỉ hỗ trợ quote tin nhắn text trong PAM app.',
      );
    }

    final isGroup = threadType == ZaloThreadType.group;
    final params = <String, dynamic>{
      'message': trimmedContent,
      'clientId': DateTime.now().millisecondsSinceEpoch,
      'ttl': 0,
      if (isGroup) 'grid': threadId.trim() else 'toid': threadId.trim(),
      if (isGroup) 'visibility': 0,
      if (!isGroup) 'imei': _credentials.imei,
    };

    if (quote != null) {
      final quoteAttach = _quoteAttachPayload(quote);
      params.addAll({
        'qmsgOwner': quote.ownerId,
        'qmsgId': quote.msgId,
        'qmsgCliId': quote.cliMsgId,
        'qmsgType': _clientMessageType(quote.msgType),
        'qmsgTs': quote.timestamp,
        'qmsg': quote.content is String ? quote.content : '',
        if (isGroup && quoteAttach != null) 'qmsgAttach': quoteAttach,
        'qmsgTTL': quote.ttl,
      });
    }

    final baseUrl = _serviceEndpoint(isGroup ? 'group' : 'chat');
    final path = quote != null
        ? (isGroup ? '/api/group/quote' : '/api/message/quote')
        : (isGroup ? '/api/group/sendmsg' : '/api/message/sms');

    final response = await _post(
      _makeUrl('$baseUrl$path', params: {'nretry': 0}),
      form: {
        'params': encodeZaloPayload(_requireSecretKey(), jsonEncode(params)),
      },
    );

    return ZaloSendResult.fromJson(_asMap(_resolveResponseData(response)));
  }

  Future<void> keepAlive() async {
    final secretKey = _requireSecretKey();
    final chatEndpoint = _serviceEndpoint('chat');
    final params = encodeZaloPayload(
      secretKey,
      jsonEncode({'imei': _credentials.imei}),
    );

    final response = await _get(
      _makeUrl('$chatEndpoint/keepalive', params: {'params': params}),
    );
    _resolveResponseData(response, isEncrypted: false);
  }

  Future<Map<String, String>> getAllGroups() async {
    final groupPollEndpoint = _serviceEndpoint('group_poll');
    final response = await _get(
      _makeUrl('$groupPollEndpoint/api/group/getlg/v4'),
    );
    final data = _asMap(_resolveResponseData(response));

    return _asMap(
      data['gridVerMap'],
    ).map((key, value) => MapEntry(key, value.toString()));
  }

  Future<List<ZaloFriend>> listFriends({
    int count = 20000,
    int page = 1,
  }) async {
    final profileEndpoint = _serviceEndpoint('profile');
    final params = encodeZaloPayload(
      _requireSecretKey(),
      jsonEncode({
        'incInvalid': 1,
        'page': page,
        'count': count,
        'avatar_size': 120,
        'actiontime': 0,
        'imei': _credentials.imei,
      }),
    );

    final response = await _get(
      _makeUrl(
        '$profileEndpoint/api/social/friend/getfriends',
        params: {'params': params},
      ),
    );
    final items = _friendItemsFromResponseData(_resolveResponseData(response));
    final seenIds = <String>{};
    final friends = <ZaloFriend>[];

    for (final item in items) {
      final friend = ZaloFriend.fromJson(_asMap(item));
      if (friend.userId.isEmpty || !seenIds.add(friend.userId)) {
        continue;
      }

      friends.add(friend);
    }

    friends.sort((left, right) {
      return left.displayName.toLowerCase().compareTo(
        right.displayName.toLowerCase(),
      );
    });
    return List<ZaloFriend>.unmodifiable(friends);
  }

  /// Backward-compatible: trả về map như trước, nay tự chunk + throttle.
  Future<Map<String, ZaloGroupInfo>> getGroupInfo(
    Iterable<String> groupIds, {
    Map<String, int>? versions,
  }) async {
    final batch = await fetchGroupInfoBatch(groupIds, versions: versions);
    return batch.infos;
  }

  /// Fetch group info theo id, tự chia lô ([batchSize]), giãn cách ([throttle])
  /// và backoff khi lỗi. Trả về cả nhóm bị remove/unchanged để caller ngừng
  /// retry những nhóm không còn lấy được info.
  Future<ZaloGroupInfoBatch> fetchGroupInfoBatch(
    Iterable<String> groupIds, {
    Map<String, int>? versions,
    int batchSize = 50,
    Duration throttle = const Duration(milliseconds: 300),
  }) async {
    final chunks = chunkZaloIds(groupIds, batchSize);
    if (chunks.isEmpty) {
      return ZaloGroupInfoBatch.empty;
    }

    final infos = <String, ZaloGroupInfo>{};
    final removed = <String>[];
    final unchanged = <String>[];
    final groupEndpoint = _serviceEndpoint('group');

    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final params = encodeZaloPayload(
        _requireSecretKey(),
        jsonEncode({
          'gridVerMap': jsonEncode({
            for (final groupId in chunk) groupId: versions?[groupId] ?? 0,
          }),
        }),
      );
      final response = await _postWithBackoff(
        _makeUrl('$groupEndpoint/api/group/getmg-v2'),
        form: {'params': params},
      );
      final batch = parseZaloGroupInfoResponse(
        _asMap(_resolveResponseData(response)),
      );
      infos.addAll(batch.infos);
      removed.addAll(batch.removedGroupIds);
      unchanged.addAll(batch.unchangedGroupIds);

      if (i < chunks.length - 1 && throttle > Duration.zero) {
        await Future<void>.delayed(throttle);
      }
    }

    return ZaloGroupInfoBatch(
      infos: infos,
      removedGroupIds: removed,
      unchangedGroupIds: unchanged,
    );
  }

  Future<ZaloGroupChatHistory> getGroupChatHistory(
    String groupId, {
    int count = 50,
  }) async {
    final trimmedGroupId = groupId.trim();
    if (trimmedGroupId.isEmpty) {
      throw const ZaloLoginException('Thiếu group id để tải lịch sử chat.');
    }

    final uid = _uid;
    if (uid == null || uid.isEmpty) {
      throw const ZaloLoginException(
        'Phiên Zalo chưa sẵn sàng để tải lịch sử chat.',
      );
    }

    final groupEndpoint = _serviceEndpoint('group');
    final response = await _get(
      _makeUrl(
        '$groupEndpoint/api/group/history',
        params: {
          'params': encodeZaloPayload(
            _requireSecretKey(),
            jsonEncode({'grid': trimmedGroupId, 'count': count}),
          ),
        },
      ),
    );

    return ZaloGroupChatHistory.fromJson(
      uid,
      _asMap(_resolveResponseData(response)),
    );
  }

  Future<List<ZaloGroup>> listGroups() async {
    final versions = await getAllGroups();
    final infoMap = await getGroupInfo(versions.keys);
    final groups = <ZaloGroup>[];

    for (final entry in versions.entries) {
      final info = infoMap[entry.key];
      if (info == null) {
        continue;
      }

      groups.add(ZaloGroup.fromInfo(info, version: entry.value));
    }

    groups.sort((left, right) => left.name.compareTo(right.name));
    return List<ZaloGroup>.unmodifiable(groups);
  }

  Future<Map<String, dynamic>> _callLoginApi() async {
    final encryptor = ZaloLoginParamsEncryptor(
      type: _apiType,
      imei: _credentials.imei,
      firstLaunchTime: _firstLaunchTime,
      randomStringBuilder: _randomStringBuilder,
    );

    final baseParams = <String, dynamic>{
      'zcid': encryptor.zcid,
      'zcid_ext': encryptor.zcidExt,
      'enc_ver': encryptor.encVersion,
      'params': encryptor.encodeData(
        jsonEncode({
          'computer_name': _computerName,
          'imei': _credentials.imei,
          'language': _language,
          'ts': DateTime.now().millisecondsSinceEpoch,
        }),
      ),
      'type': _apiType,
      'client_version': _apiVersion,
    };

    final queryParams = Map<String, dynamic>.from(baseParams)
      ..['signkey'] = buildZaloSignKey('getlogininfo', baseParams)
      ..['nretry'] = 0;

    zaloLog('Calling Zalo getLoginInfo', name: _logName);
    final response = await _get(_makeUrl(_loginInfoUrl, params: queryParams));
    final payload = _decodeJson(response.data ?? '{}');
    final encryptedData = payload['data'] as String?;

    if (encryptedData == null || encryptedData.isEmpty) {
      final message = payload['error_message'] as String?;
      final logData = <String, Object?>{
        'errorCode': _asInt(payload['error_code']),
      };
      if (message != null) {
        logData['errorMessage'] = message;
      }
      zaloLog(
        'Zalo getLoginInfo returned no encrypted data',
        name: _logName,
        data: logData,
      );
      throw ZaloLoginException(
        message ?? 'Không lấy được dữ liệu khởi tạo phiên từ Zalo.',
      );
    }

    final decodedPayload = _decodeJson(
      decodeZaloLoginPayload(encryptor.encryptKey, encryptedData),
    );
    return _asMap(decodedPayload['data']);
  }

  Future<Map<String, dynamic>> _callGetServerInfo() async {
    final baseParams = <String, dynamic>{
      'imei': _credentials.imei,
      'type': _apiType,
      'client_version': _apiVersion,
      'computer_name': _computerName,
    };

    final queryParams = Map<String, dynamic>.from(baseParams)
      ..['signkey'] = buildZaloSignKey('getserverinfo', baseParams);

    zaloLog('Calling Zalo getServerInfo', name: _logName);
    final response = await _get(
      _makeUrl(_serverInfoUrl, params: queryParams, includeApiVersion: false),
    );
    final payload = _decodeJson(response.data ?? '{}');

    final errorCode = payload.containsKey('error_code')
        ? _asInt(payload['error_code'])
        : 0;
    if (errorCode != 0) {
      final logData = <String, Object?>{'errorCode': errorCode};
      if (payload['error_message'] != null) {
        logData['errorMessage'] = payload['error_message'];
      }
      zaloLog(
        'Zalo getServerInfo returned error',
        name: _logName,
        data: logData,
      );
      throw ZaloLoginException(
        payload['error_message'] as String? ??
            'Không lấy được cấu hình server từ Zalo.',
      );
    }

    return _asMap(payload['data']);
  }

  Future<ZaloProfile> _getLegacyAccountInfo() async {
    await _get(_checkSessionUrl);

    final response = await _get(_userInfoUrl);
    final payload = _decodeJson(response.data ?? '{}');
    final profile = ZaloProfile.fromUserInfoJson(payload);

    final data = payload['data'];
    if (data is Map) {
      final normalized = Map<String, dynamic>.from(data);
      final logged = normalized['logged'] as bool? ?? false;
      if (!logged) {
        unawaited(_handleSessionExpired());
        throw const ZaloLoginException(
          'Phiên Zalo đã hết hạn. Vui lòng kết nối lại.',
        );
      }
    }

    if (!profile.sessionChatValid) {
      unawaited(_handleSessionExpired());
      throw const ZaloLoginException(
        'Zalo chưa sẵn sàng cho phiên chat. Vui lòng thử lại.',
      );
    }

    return profile;
  }

  Future<void> _connectListener() async {
    if (_isConnectingListener ||
        _listenerSocket != null ||
        _manualListenerStop) {
      return;
    }

    _isConnectingListener = true;
    try {
      final uri = Uri.parse(
        _makeUrl(
          _wsUrls[_currentWsIndex],
          params: {'t': DateTime.now().millisecondsSinceEpoch},
        ),
      );
      zaloLog(
        'Connecting realtime listener socket',
        name: _logName,
        data: {'uri': uri.toString(), 'wsIndex': _currentWsIndex},
      );
      final socket = await _socketConnector(
        uri,
        headers: _buildWsHeaders(uri),
      ).timeout(_connectTimeout);

      if (_manualListenerStop) {
        await socket.close(_manualCloseCode, 'manual');
        return;
      }

      _listenerSocket = socket;
      _listenerRetryCounts.clear();
      zaloLog(
        'Realtime listener socket connected',
        name: _logName,
        data: {'wsIndex': _currentWsIndex, 'closeCode': socket.closeCode},
      );
      _listenerSubscription = socket.stream.listen(
        (data) {
          // Any inbound frame proves the socket is still live. Reset the
          // watchdog so a genuinely healthy connection is never force-closed.
          _markListenerAlive();
          unawaited(_handleRealtimeData(data));
        },
        onError: (error, stackTrace) {
          _messageController?.addError(error, stackTrace);
        },
        onDone: () => unawaited(
          _handleListenerClosed(
            socket.closeCode ?? _abnormalCloseCode,
            socket.closeReason ?? '',
          ),
        ),
        cancelOnError: false,
      );
      // Start the liveness watchdog immediately: a socket that connects but
      // never even delivers the cipher-key frame is already dead.
      _armLivenessWatchdog();
    } catch (error, stackTrace) {
      zaloLog(
        'Realtime listener connection failed',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
      _messageController?.addError(error, stackTrace);
      await _handleListenerClosed(_abnormalCloseCode, error.toString());
    } finally {
      _isConnectingListener = false;
    }
  }

  /// Giải mã realtime payload, trả về `null` (thay vì ném lỗi) nếu gói tin không
  /// giải mã được. Ported từ zca-js PR #303: một số event reaction/hệ thống gửi
  /// gói không decode được — bỏ qua thay vì để lỗi làm sập listener.
  Future<Map<String, dynamic>?> _tryDecodeRealtimeEvent(
    Map<String, dynamic> parsed,
  ) async {
    try {
      return await decodeZaloRealtimeEvent(parsed, _cipherKey);
    } catch (error) {
      zaloLog(
        'Bỏ qua gói tin Zalo realtime không giải mã được '
        '(bình thường với một số event reaction/hệ thống)',
        name: _logName,
        data: {'reason': error.toString()},
      );
      return null;
    }
  }

  Future<void> _handleRealtimeData(dynamic data) async {
    try {
      final uid = _uid;
      if (uid == null || uid.isEmpty) {
        return;
      }

      final frame = parseZaloRealtimeFrame(data);
      if (frame == null) {
        return;
      }

      zaloLog(
        'Realtime listener frame received',
        name: _logName,
        data: {
          'version': frame.version,
          'cmd': frame.cmd,
          'subCmd': frame.subCmd,
          'bodyLength': frame.body.length,
        },
      );

      final parsed = _decodeJson(frame.body);
      _logZaloRealtimePayload('ZALO REALTIME FRAME BODY', frame, parsed);
      if (frame.version == 1 &&
          frame.cmd == 1 &&
          frame.subCmd == 1 &&
          parsed['key'] is String) {
        _cipherKey = parsed['key'] as String;
        zaloLog(
          'Realtime listener cipher key received',
          name: _logName,
          data: {'keyLength': _cipherKey?.length ?? 0},
        );
        _startRealtimePing();
        return;
      }

      if (frame.version == 1 &&
          frame.cmd == _duplicateConnectionCloseCode &&
          frame.subCmd == 0) {
        zaloLog('Zalo realtime duplicate connection frame', name: _logName);
        await _handleSessionInvalidated(ZaloSessionEndReason.takenOver);
        return;
      }

      if (frame.version != 1) {
        return;
      }

      if (frame.cmd == 501 && frame.subCmd == 0) {
        final payload = await _tryDecodeRealtimeEvent(parsed);
        if (payload == null) {
          return;
        }
        _logZaloRealtimePayload(
          'ZALO REALTIME DECODED PAYLOAD',
          frame,
          payload,
        );
        final dataMap = _unwrapRealtimeData(payload);
        final msgs = _asDynamicList(dataMap['msgs']);
        zaloLog(
          'Received user realtime payload',
          name: _logName,
          data: {'count': msgs.length},
        );
        for (final item in msgs) {
          _messageController?.add(ZaloMessage.fromUser(uid, _asMap(item)));
        }
        return;
      }

      if (frame.cmd == 521 && frame.subCmd == 0) {
        final payload = await _tryDecodeRealtimeEvent(parsed);
        if (payload == null) {
          return;
        }
        _logZaloRealtimePayload(
          'ZALO REALTIME DECODED PAYLOAD',
          frame,
          payload,
        );
        final dataMap = _unwrapRealtimeData(payload);
        final groupMsgs = _asDynamicList(dataMap['groupMsgs']);
        zaloLog(
          'Received group realtime payload',
          name: _logName,
          data: {'count': groupMsgs.length},
        );
        for (final item in groupMsgs) {
          _messageController?.add(ZaloMessage.fromGroup(uid, _asMap(item)));
        }
        return;
      }

      zaloLog(
        'Unhandled realtime listener frame',
        name: _logName,
        data: {
          'version': frame.version,
          'cmd': frame.cmd,
          'subCmd': frame.subCmd,
        },
      );
      await _logUnknownZaloRealtimePayload(frame, parsed);
    } catch (error, stackTrace) {
      zaloLog(
        'Realtime listener frame handling failed',
        name: _logName,
        error: error,
        stackTrace: stackTrace,
      );
      _messageController?.addError(error, stackTrace);
    }
  }

  Future<void> _handleListenerClosed(int closeCode, String closeReason) async {
    _pingTimer?.cancel();
    _pingTimer = null;
    _livenessTimer?.cancel();
    _livenessTimer = null;
    _cipherKey = null;

    // Do NOT await this cancel: _handleListenerClosed runs from the socket
    // subscription's own onDone, and awaiting a self-cancel can stall the whole
    // reconnect. The old subscription is bound to the now-dead socket, so a
    // fire-and-forget teardown is safe — the retry below builds a fresh one.
    final closingSubscription = _listenerSubscription;
    _listenerSubscription = null;
    unawaited(closingSubscription?.cancel());
    _listenerSocket = null;

    if (_manualListenerStop || !_retryListenerOnClose) {
      zaloLog(
        'Realtime listener closed without retry',
        name: _logName,
        data: {'closeCode': closeCode, 'closeReason': closeReason},
      );
      return;
    }

    if (_isSessionInvalidationCloseCode(closeCode)) {
      zaloLog(
        'Zalo realtime listener invalidated',
        name: _logName,
        data: {'closeCode': closeCode, 'closeReason': closeReason},
      );
      await _handleSessionInvalidated(ZaloSessionEndReason.takenOver);
      return;
    }

    final delayMs = _nextRetryDelay(closeCode);
    if (delayMs == null) {
      if (_shouldRotateWsEndpoint(closeCode)) {
        _rotateWsEndpoint();
      }
      zaloLog(
        'Realtime listener closed without retry schedule',
        name: _logName,
        data: {'closeCode': closeCode, 'closeReason': closeReason},
      );
      // Do NOT die silently: surface the closure so consumers (the background
      // service isolate) get an onError and can re-arm the listener, mirroring
      // how zca-js emits a `closed` event for the caller to restart.
      _messageController?.addError(
        ZaloListenerClosedException(closeCode, closeReason),
      );
      return;
    }

    if (_shouldRotateWsEndpoint(closeCode)) {
      _rotateWsEndpoint();
    }

    _reconnectTimer?.cancel();
    zaloLog(
      'Scheduling realtime listener reconnect',
      name: _logName,
      data: {
        'closeCode': closeCode,
        'closeReason': closeReason,
        'delayMs': delayMs,
        'wsIndex': _currentWsIndex,
      },
    );
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      unawaited(_connectListener());
    });
  }

  void _startRealtimePing() {
    _pingTimer?.cancel();
    final intervalMs = _asInt(_socketSettings['ping_interval']);
    final safeIntervalMs = intervalMs > 0 ? intervalMs : 18000;

    _pingTimer = Timer.periodic(Duration(milliseconds: safeIntervalMs), (_) {
      _sendRealtimeFrame(
        version: 1,
        cmd: 2,
        subCmd: 1,
        data: {'eventId': DateTime.now().millisecondsSinceEpoch},
        requireId: false,
      );
    });
  }

  // The application ping (cmd 2) is fire-and-forget and there is no pong ack,
  // so a half-open socket (mobile NAT timeout, carrier drop, wifi<->4G switch)
  // stays "connected" from the OS view while silently delivering nothing —
  // onDone/onError never fire. This watchdog is the only thing that notices:
  // if no inbound frame arrives within the grace window, we force-close the
  // socket, which routes through onDone -> _handleListenerClosed -> reconnect.
  void _armLivenessWatchdog() {
    _livenessTimer?.cancel();
    final pingIntervalMs = _asInt(_socketSettings['ping_interval']);
    final safePingIntervalMs = pingIntervalMs > 0 ? pingIntervalMs : 18000;
    // Zalo pushes NOTHING on an idle connection (verified on-device: only the
    // cipher-key frame arrives, then silence), so "no inbound data" cannot mean
    // "dead" until it has lasted well beyond any normal quiet spell. A busy
    // ride-hailing group resets this constantly via real message frames, so the
    // watchdog only ever fires on genuinely stalled/half-open sockets. Keep the
    // floor generous (5 min) to avoid churning a quiet-but-healthy connection.
    final livenessMs = math.max(safePingIntervalMs * 10, 300000);
    _livenessTimer = Timer(
      Duration(milliseconds: livenessMs),
      _onListenerStalled,
    );
  }

  void _markListenerAlive() {
    // Never resurrect the watchdog after a manual stop or once the socket is
    // already gone — that would keep a dangling timer alive forever.
    if (_manualListenerStop || _listenerSocket == null) {
      return;
    }
    _armLivenessWatchdog();
  }

  void _onListenerStalled() {
    final socket = _listenerSocket;
    if (socket == null) {
      return;
    }
    zaloLog(
      'Realtime listener stalled (no data within liveness window), '
      'forcing reconnect',
      name: _logName,
    );
    // Force-close the dead socket; onDone drives the normal reconnect path.
    unawaited(socket.close(_livenessCloseCode, 'liveness_timeout'));
  }

  void _sendRealtimeFrame({
    required int version,
    required int cmd,
    required int subCmd,
    required Map<String, dynamic> data,
    bool requireId = true,
  }) {
    final socket = _listenerSocket;
    if (socket == null) {
      return;
    }

    final payload = Map<String, dynamic>.from(data);
    if (requireId) {
      payload['req_id'] = 'req_${_wsMessageId++}';
    }

    _logZaloRealtimePayload(
      'ZALO REALTIME OUTGOING FRAME',
      ZaloRealtimeFrame(
        version: version,
        cmd: cmd,
        subCmd: subCmd,
        body: jsonEncode(payload),
      ),
      payload,
    );
    socket.add(
      buildZaloRealtimeFrame(
        version: version,
        cmd: cmd,
        subCmd: subCmd,
        data: payload,
      ),
    );
  }

  Future<Response<String>> _get(String url) {
    return _request('GET', url);
  }

  Future<Response<String>> _post(
    String url, {
    required Map<String, String> form,
  }) {
    return _request(
      'POST',
      url,
      body: form,
      contentType: Headers.formUrlEncodedContentType,
    );
  }

  /// POST với exponential backoff cho lỗi tạm thời (rate-limit / mạng). Ném lại
  /// lỗi sau [maxRetries] lần.
  Future<Response<String>> _postWithBackoff(
    String url, {
    required Map<String, String> form,
    int maxRetries = 3,
  }) async {
    for (var attempt = 1; ; attempt++) {
      try {
        return await _post(url, form: form);
      } catch (error) {
        if (attempt >= maxRetries) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
      }
    }
  }

  Future<Response<String>> _request(
    String method,
    String url, {
    Map<String, String>? headers,
    Object? body,
    String? contentType,
  }) async {
    _logDecodedZaloRequest(method, url, body: body);
    final response = await _client.request<String>(
      url,
      data: body,
      options: Options(
        method: method,
        headers: _buildHeaders(url, headers: headers, contentType: contentType),
        contentType: contentType,
        extra: _buildRequestLogExtras(),
      ),
    );

    final statusCode = response.statusCode ?? 0;
    zaloLog(
      'Zalo runtime HTTP response',
      name: _logName,
      data: {
        'method': method,
        'host': Uri.tryParse(url)?.host ?? '',
        'path': Uri.tryParse(url)?.path ?? url,
        'status': statusCode,
      },
    );
    if (statusCode == 401) {
      unawaited(_handleSessionInvalidated(ZaloSessionEndReason.unauthorized));
      throw const ZaloLoginException('Zalo từ chối phiên đăng nhập (401).');
    }
    if (statusCode < 200 || statusCode >= 400) {
      throw ZaloLoginException('Yêu cầu Zalo thất bại với mã $statusCode.');
    }

    return response;
  }

  Map<String, Object?> _buildRequestLogExtras() {
    if (!_shouldLogDecodedZaloPayloads) {
      return const <String, Object?>{};
    }

    final secretKey = _secretKey;
    if (secretKey == null || secretKey.isEmpty) {
      return const <String, Object?>{};
    }

    return <String, Object?>{
      ZaloCurlLoggingInterceptor.responseDecoderExtraKey:
          _decodeZaloResponseForCurlLog,
    };
  }

  Object? _decodeZaloResponseForCurlLog(Object? data) {
    final rawBody = data?.toString() ?? '';
    if (rawBody.isEmpty) {
      return null;
    }

    final payload = _decodeJson(rawBody);
    final responseData = payload['data'];
    if (responseData is! String || responseData.isEmpty) {
      return payload;
    }

    final decodedRaw = decodeZaloPayload(_requireSecretKey(), responseData);
    return _tryDecodeLogJson(decodedRaw);
  }

  Map<String, String> _buildHeaders(
    String url, {
    Map<String, String>? headers,
    String? contentType,
  }) {
    final origin = Uri.tryParse(url)?.origin ?? _chatOrigin;
    final contentTypeHeaders = contentType == null
        ? null
        : <String, String>{'Content-Type': contentType};

    return <String, String>{
      'User-Agent': _credentials.userAgent,
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'vi-VN,vi;q=0.9',
      'Cookie': _credentials.cookie,
      'Origin': _chatOrigin,
      'Referer': '$origin/',
      ...?contentTypeHeaders,
      ...?headers,
    };
  }

  Map<String, dynamic> _buildWsHeaders(Uri uri) {
    return <String, dynamic>{
      'Cookie': _credentials.cookie,
      'Origin': _chatOrigin,
      'User-Agent': _credentials.userAgent,
      'Accept-Language': 'vi-VN,vi;q=0.9',
      'Host': uri.host,
    };
  }

  String _makeUrl(
    String baseUrl, {
    Map<String, dynamic> params = const <String, dynamic>{},
    bool includeApiVersion = true,
  }) {
    final uri = Uri.parse(baseUrl);
    final query = <String, String>{};

    query.addAll(uri.queryParameters);
    for (final entry in params.entries) {
      query[entry.key] = entry.value.toString();
    }

    if (includeApiVersion) {
      query.putIfAbsent('zpw_ver', () => _apiVersion.toString());
      query.putIfAbsent('zpw_type', () => _apiType.toString());
    }

    return uri.replace(queryParameters: query).toString();
  }

  String _serviceEndpoint(String service) {
    final endpoints = _serviceMap[service];
    if (endpoints == null || endpoints.isEmpty) {
      throw ZaloLoginException(
        'Zalo không cấu hình endpoint cho service `$service`.',
      );
    }

    return endpoints.first;
  }

  String _requireSecretKey() {
    final secretKey = _secretKey;
    if (secretKey == null || secretKey.isEmpty) {
      throw const ZaloLoginException(
        'Phiên Zalo chưa được khởi tạo. Hãy gọi initSession() trước.',
      );
    }

    return secretKey;
  }

  Map<String, dynamic> get _socketSettings {
    return _asMap(_asMap(_settings['features'])['socket']);
  }

  bool get _shouldLogDecodedZaloPayloads => kDebugMode;

  int? _nextRetryDelay(int closeCode) {
    final closeCodes = _asIntList(_socketSettings['close_and_retry_codes']);
    if (closeCodes.isNotEmpty && closeCodes.contains(closeCode)) {
      final retryConfig = _asMap(
        _asMap(_socketSettings['retries'])[closeCode.toString()],
      );
      final max = _asInt(retryConfig['max']);
      final times = _asIntList(retryConfig['times']);
      if (max <= 0 || times.isEmpty) {
        return _nextFallbackRetryDelay(closeCode);
      }

      final nextCount = (_listenerRetryCounts[closeCode] ?? 0) + 1;
      if (nextCount > max) {
        return null;
      }

      _listenerRetryCounts[closeCode] = nextCount;
      final delayIndex = nextCount - 1;
      return delayIndex < times.length ? times[delayIndex] : times.last;
    }

    return _nextFallbackRetryDelay(closeCode);
  }

  bool _shouldRotateWsEndpoint(int closeCode) {
    final rotateCodes = _asIntList(_socketSettings['rotate_error_codes']);
    return rotateCodes.contains(closeCode) &&
        _currentWsIndex < _wsUrls.length - 1;
  }

  void _rotateWsEndpoint() {
    if (_currentWsIndex < _wsUrls.length - 1) {
      _currentWsIndex++;
    }
  }

  Map<String, dynamic> _unwrapRealtimeData(Map<String, dynamic> payload) {
    final data = payload['data'];
    if (data is Map) {
      return _asMap(data);
    }

    return payload;
  }

  dynamic _resolveResponseData(
    Response<String> response, {
    bool isEncrypted = true,
  }) {
    final payload = _decodeJson(response.data ?? '{}');

    final topLevelErrorCode = payload.containsKey('error_code')
        ? _asInt(payload['error_code'])
        : 0;
    if (topLevelErrorCode != 0) {
      final errorMessage = payload['error_message'] as String?;
      final logData = <String, Object?>{'errorCode': topLevelErrorCode};
      if (errorMessage != null) {
        logData['errorMessage'] = errorMessage;
      }
      zaloLog(
        'Zalo runtime top-level error',
        name: _logName,
        data: logData,
      );
      if (_isSessionInvalidationError(topLevelErrorCode)) {
        unawaited(_handleSessionInvalidated(ZaloSessionEndReason.takenOver));
      } else if (_isSessionExpiredError(topLevelErrorCode, errorMessage)) {
        unawaited(_handleSessionExpired());
      }
      throw ZaloLoginException(errorMessage ?? 'Yêu cầu Zalo thất bại.');
    }

    final data = payload['data'];
    if (!isEncrypted) {
      _logDecodedZaloResponse(response, 'ZALO DECODED RESPONSE DATA', data);
      return data;
    }
    if (data is! String || data.isEmpty) {
      throw const ZaloLoginException('Zalo trả về dữ liệu không hợp lệ.');
    }

    final decodedPayloadRaw = decodeZaloPayload(_requireSecretKey(), data);
    final decodedPayload = _decodeJson(decodedPayloadRaw);
    _logDecodedZaloResponse(
      response,
      'ZALO DECODED RESPONSE PAYLOAD',
      decodedPayload,
      rawBody: decodedPayloadRaw,
    );
    final nestedErrorCode = decodedPayload.containsKey('error_code')
        ? _asInt(decodedPayload['error_code'])
        : 0;
    if (nestedErrorCode != 0) {
      final errorMessage = decodedPayload['error_message'] as String?;
      final logData = <String, Object?>{'errorCode': nestedErrorCode};
      if (errorMessage != null) {
        logData['errorMessage'] = errorMessage;
      }
      zaloLog('Zalo runtime nested error', name: _logName, data: logData);
      if (_isSessionInvalidationError(nestedErrorCode)) {
        unawaited(_handleSessionInvalidated(ZaloSessionEndReason.takenOver));
      } else if (_isSessionExpiredError(nestedErrorCode, errorMessage)) {
        unawaited(_handleSessionExpired());
      }
      throw ZaloLoginException(
        errorMessage ?? 'Không giải mã được dữ liệu từ Zalo.',
      );
    }

    _logDecodedZaloResponse(
      response,
      'ZALO DECODED RESPONSE DATA',
      decodedPayload['data'],
    );
    return decodedPayload['data'];
  }

  void _logDecodedZaloRequest(String method, String url, {Object? body}) {
    if (!_shouldLogDecodedZaloPayloads) {
      return;
    }

    final secretKey = _secretKey;
    if (secretKey == null || secretKey.isEmpty) {
      return;
    }

    final uri = Uri.tryParse(url);
    final queryParams = uri?.queryParameters['params'];
    if (queryParams != null && queryParams.isNotEmpty) {
      _logDecodedZaloRequestParams(
        method,
        uri?.toString() ?? url,
        'QUERY PARAMS',
        secretKey,
        queryParams,
      );
    }

    if (body is Map && body['params'] != null) {
      _logDecodedZaloRequestParams(
        method,
        uri?.toString() ?? url,
        'FORM PARAMS',
        secretKey,
        body['params'].toString(),
      );
    }
  }

  void _logDecodedZaloRequestParams(
    String method,
    String url,
    String source,
    String secretKey,
    String encryptedPayload,
  ) {
    try {
      final decodedRaw = decodeZaloPayload(secretKey, encryptedPayload);
      final decodedData = _tryDecodeLogJson(decodedRaw);
      final body = _formatZaloLogValue(decodedData);
      developer.log(
        '[$_logName] ZALO DECODED REQUEST $source $method $url '
        'type=${decodedData.runtimeType} length=${body.length} $body',
        name: _logName,
      );
    } catch (error) {
      developer.log(
        '[$_logName] ZALO DECODED REQUEST $source $method $url failed=$error',
        name: _logName,
      );
    }
  }

  void _logDecodedZaloResponse(
    Response<String> response,
    String label,
    Object? data, {
    String? rawBody,
  }) {
    if (!_shouldLogDecodedZaloPayloads) {
      return;
    }

    final body = rawBody ?? _formatZaloLogValue(data);
    final request = response.requestOptions;
    developer.log(
      '[$_logName] $label ${request.method} ${request.uri} '
      'type=${data.runtimeType} length=${body.length} $body',
      name: _logName,
    );
  }

  Future<void> _logUnknownZaloRealtimePayload(
    ZaloRealtimeFrame frame,
    Map<String, dynamic> parsed,
  ) async {
    if (!_shouldLogDecodedZaloPayloads || parsed['data'] is! String) {
      return;
    }

    try {
      final payload = await decodeZaloRealtimeEvent(parsed, _cipherKey);
      _logZaloRealtimePayload(
        'ZALO REALTIME DECODED UNKNOWN PAYLOAD',
        frame,
        payload,
      );
    } catch (error) {
      _logZaloRealtimePayload('ZALO REALTIME DECODE UNKNOWN FAILED', frame, {
        'error': error.toString(),
        'parsed': parsed,
      });
    }
  }

  void _logZaloRealtimePayload(
    String label,
    ZaloRealtimeFrame frame,
    Object? data,
  ) {
    if (!_shouldLogDecodedZaloPayloads) {
      return;
    }
    if (frame.version == 1 && frame.cmd == 2) {
      return;
    }

    final body = _formatZaloLogValue(data);
    developer.log(
      '[$_logName] $label version=${frame.version} cmd=${frame.cmd} '
      'subCmd=${frame.subCmd} type=${data.runtimeType} '
      'length=${body.length} $body',
      name: _logName,
    );
  }

  int? _nextFallbackRetryDelay(int closeCode) {
    // Session invalidation (duplicate/kicked) is terminal — it needs a fresh
    // login, not a reconnect — and is already routed away before we get here.
    // A manual stop is caught earlier via `_manualListenerStop`, so a bare
    // `_manualCloseCode` (1000) reaching this point means the SERVER closed us
    // normally while we still want to listen: keep retrying instead of dying.
    if (_isSessionInvalidationCloseCode(closeCode)) {
      return null;
    }

    const fallbackTimes = <int>[5000, 10000, 30000, 60000];
    final nextCount = (_listenerRetryCounts[closeCode] ?? 0) + 1;
    _listenerRetryCounts[closeCode] = nextCount;
    final delayIndex = math.min(nextCount - 1, fallbackTimes.length - 1);
    return fallbackTimes[delayIndex];
  }

  bool _isSessionExpiredError(int errorCode, String? errorMessage) {
    final normalizedMessage = (errorMessage ?? '').toLowerCase().trim();
    if (normalizedMessage.isEmpty) {
      return false;
    }

    const sessionHints = <String>[
      'hết hạn',
      'het han',
      'session expired',
      'invalid session',
      'not logged in',
      'đăng nhập lại',
      'dang nhap lai',
      'login again',
      're-login',
      'relogin',
    ];
    return sessionHints.any(normalizedMessage.contains);
  }

  bool _isSessionInvalidationError(int errorCode) {
    return errorCode == _duplicateConnectionCloseCode ||
        errorCode == _kickConnectionCloseCode;
  }

  bool _isSessionInvalidationCloseCode(int closeCode) {
    return closeCode == _duplicateConnectionCloseCode ||
        closeCode == _kickConnectionCloseCode;
  }

  Future<void> _handleSessionExpired() async {
    if (_isHandlingSessionExpiry) {
      return;
    }

    _isHandlingSessionExpiry = true;
    try {
      await stopListener(closeStream: false);
      try {
        await _onSessionExpired?.call();
      } catch (_) {}
    } finally {
      _isHandlingSessionExpiry = false;
    }
  }

  Future<void> _handleSessionInvalidated(ZaloSessionEndReason reason) async {
    if (_isHandlingSessionInvalidation) {
      return;
    }

    _isHandlingSessionInvalidation = true;
    try {
      await stopListener(closeStream: false);
      try {
        await _onSessionInvalidated?.call(reason);
      } catch (_) {}
    } finally {
      _isHandlingSessionInvalidation = false;
    }
  }
}

class ZaloLoginParamsEncryptor {
  ZaloLoginParamsEncryptor({
    required int type,
    required String imei,
    required int firstLaunchTime,
    required String Function(int? minLength, int? maxLength)
    randomStringBuilder,
  }) : _type = type,
       _imei = imei,
       _firstLaunchTime = firstLaunchTime,
       _randomStringBuilder = randomStringBuilder {
    zcid = _createZcid();
    zcidExt = _randomStringBuilder(6, 12);
    encryptKey = _createEncryptKey();
  }

  static const _zcidSeedKey = '3FC4F0D2AB50057BCE0D90D9187A22B1';

  final int _type;
  final String _imei;
  final int _firstLaunchTime;
  final String Function(int? minLength, int? maxLength) _randomStringBuilder;

  late final String zcid;
  late final String zcidExt;
  late final String encryptKey;

  String get encVersion => 'v2';

  String encodeData(String data) {
    return _encodeUtf8Aes(encryptKey, data, output: AesOutputEncoding.base64);
  }

  String _createZcid() {
    return _encodeUtf8Aes(
      _zcidSeedKey,
      '$_type,$_imei,$_firstLaunchTime',
      output: AesOutputEncoding.hex,
      uppercase: true,
    );
  }

  String _createEncryptKey() {
    final digest = md5.convert(utf8.encode(zcidExt)).toString().toUpperCase();
    final digestChars = _splitEvenOdd(digest);
    final zcidChars = _splitEvenOdd(zcid);

    final reversedOddChars = zcidChars.odd.reversed.toList();
    return <String>[
      ...digestChars.even.take(8),
      ...zcidChars.even.take(12),
      ...reversedOddChars.take(12),
    ].join();
  }
}

class _EvenOddCharacters {
  const _EvenOddCharacters({required this.even, required this.odd});

  final List<String> even;
  final List<String> odd;
}

enum AesOutputEncoding { base64, hex }

String buildZaloSignKey(String type, Map<String, dynamic> params) {
  final sortedKeys = params.keys.toList()..sort();
  final buffer = StringBuffer('zsecure$type');
  for (final key in sortedKeys) {
    buffer.write(params[key]);
  }

  return md5.convert(utf8.encode(buffer.toString())).toString();
}

String encodeZaloPayload(String secretKey, String data) {
  try {
    return base64Encode(
      _processAesCbc(
        key: Uint8List.fromList(base64Decode(secretKey)),
        input: Uint8List.fromList(utf8.encode(data)),
        encryptMode: true,
      ),
    );
  } catch (_) {
    throw const ZaloLoginException('Không thể mã hóa request Zalo.');
  }
}

String decodeZaloPayload(String secretKey, String data) {
  try {
    return utf8.decode(
      _processAesCbc(
        key: Uint8List.fromList(base64Decode(secretKey)),
        input: Uint8List.fromList(base64Decode(Uri.decodeComponent(data))),
        encryptMode: false,
      ),
    );
  } catch (_) {
    throw const ZaloLoginException('Không thể giải mã response Zalo.');
  }
}

String decodeZaloLoginPayload(String key, String data) {
  try {
    return utf8.decode(
      _processAesCbc(
        key: Uint8List.fromList(utf8.encode(key)),
        input: Uint8List.fromList(base64Decode(Uri.decodeComponent(data))),
        encryptMode: false,
      ),
    );
  } catch (_) {
    throw const ZaloLoginException('Không thể giải mã dữ liệu login từ Zalo.');
  }
}

String _encodeUtf8Aes(
  String key,
  String data, {
  required AesOutputEncoding output,
  bool uppercase = false,
}) {
  try {
    final encryptedData = _processAesCbc(
      key: Uint8List.fromList(utf8.encode(key)),
      input: Uint8List.fromList(utf8.encode(data)),
      encryptMode: true,
    );
    final encoded = switch (output) {
      AesOutputEncoding.base64 => base64Encode(encryptedData),
      AesOutputEncoding.hex => _hexEncode(encryptedData),
    };

    return uppercase ? encoded.toUpperCase() : encoded;
  } catch (_) {
    throw const ZaloLoginException('Không thể mã hóa tham số login Zalo.');
  }
}

Uint8List _processAesCbc({
  required Uint8List key,
  required Uint8List input,
  required bool encryptMode,
}) {
  final cipher = PaddedBlockCipherImpl(
    PKCS7Padding(),
    CBCBlockCipher(AESEngine()),
  );

  cipher.init(
    encryptMode,
    PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
      ParametersWithIV<KeyParameter>(KeyParameter(key), Uint8List(16)),
      null,
    ),
  );

  return Uint8List.fromList(cipher.process(input));
}

int _clientMessageType(String msgType) {
  switch (msgType) {
    case 'chat.voice':
      return 31;
    case 'chat.photo':
      return 32;
    case 'chat.sticker':
      return 36;
    case 'chat.doodle':
      return 37;
    case 'chat.recommended':
    case 'chat.link':
      return 38;
    case 'chat.location.new':
      return 43;
    case 'chat.video.msg':
      return 44;
    case 'share.file':
      return 46;
    case 'chat.gif':
      return 49;
    case 'webchat':
    default:
      return 1;
  }
}

String? _quoteAttachPayload(ZaloQuote quote) {
  final attach = quote.attach?.trim();
  if (attach != null && attach.isNotEmpty) {
    return attach;
  }

  final propertyExt = quote.propertyExt;
  if (propertyExt == null || propertyExt.isEmpty) {
    return null;
  }

  return jsonEncode(propertyExt);
}

/// Raised on the listener stream when the socket closes and the client has
/// decided not to auto-retry (e.g. the server's configured retry budget is
/// exhausted). Consumers should treat this as "the listener is down" and
/// re-arm it, rather than assuming the stream is still live.
class ZaloListenerClosedException implements Exception {
  const ZaloListenerClosedException(this.closeCode, this.closeReason);

  final int closeCode;
  final String closeReason;

  @override
  String toString() =>
      'ZaloListenerClosedException(code: $closeCode, reason: $closeReason)';
}

typedef ZaloSocketConnector =
    Future<ZaloWebSocketConnection> Function(
      Uri uri, {
      Map<String, dynamic>? headers,
    });

abstract class ZaloWebSocketConnection {
  Stream<dynamic> get stream;
  int? get closeCode;
  String? get closeReason;

  void add(dynamic data);
  Future<void> close([int? code, String? reason]);
}

class IoZaloWebSocketConnection implements ZaloWebSocketConnection {
  IoZaloWebSocketConnection(this._socket);

  final WebSocket _socket;

  @override
  Stream<dynamic> get stream => _socket;

  @override
  int? get closeCode => _socket.closeCode;

  @override
  String? get closeReason => _socket.closeReason;

  @override
  void add(dynamic data) {
    _socket.add(data);
  }

  @override
  Future<void> close([int? code, String? reason]) {
    return _socket.close(code, reason);
  }
}

Future<ZaloWebSocketConnection> _defaultSocketConnector(
  Uri uri, {
  Map<String, dynamic>? headers,
}) async {
  final socket = await WebSocket.connect(uri.toString(), headers: headers);
  // NB: do NOT set `socket.pingInterval` here. Zalo's realtime server does not
  // answer WebSocket protocol-level ping frames (it uses its own application
  // ping, cmd 2), so dart:io would treat every unanswered pong as a dead
  // connection and close with 1001 every ~2×interval — verified on-device as a
  // ~40s reconnect churn that drops messages. Keepalive is the app-level ping;
  // half-open detection is ZaloDartClient's receive watchdog + TCP send errors.
  return IoZaloWebSocketConnection(socket);
}

class ZaloRealtimeFrame {
  const ZaloRealtimeFrame({
    required this.version,
    required this.cmd,
    required this.subCmd,
    required this.body,
  });

  final int version;
  final int cmd;
  final int subCmd;
  final String body;
}

Uint8List buildZaloRealtimeFrame({
  required int version,
  required int cmd,
  required int subCmd,
  required Map<String, dynamic> data,
}) {
  final bodyBytes = utf8.encode(jsonEncode(data));
  final buffer = Uint8List(4 + bodyBytes.length);

  buffer[0] = version;
  buffer[1] = cmd & 0xFF;
  buffer[2] = (cmd >> 8) & 0xFF;
  buffer[3] = subCmd & 0xFF;
  buffer.setRange(4, 4 + bodyBytes.length, bodyBytes);
  return buffer;
}

ZaloRealtimeFrame? parseZaloRealtimeFrame(dynamic data) {
  Uint8List? bytes;
  if (data is Uint8List) {
    bytes = data;
  } else if (data is List<int>) {
    bytes = Uint8List.fromList(data);
  }

  if (bytes == null || bytes.length < 4) {
    return null;
  }

  final body = utf8.decode(bytes.sublist(4), allowMalformed: true);
  if (body.isEmpty) {
    return null;
  }

  return ZaloRealtimeFrame(
    version: bytes[0],
    cmd: bytes[1] | (bytes[2] << 8),
    subCmd: bytes[3],
    body: body,
  );
}

Future<Map<String, dynamic>> decodeZaloRealtimeEvent(
  Map<String, dynamic> parsed,
  String? cipherKey,
) async {
  final rawData = parsed['data'];
  final encryptType = _asInt(parsed['encrypt']);

  if (rawData is! String) {
    throw const ZaloLoginException(
      'Realtime payload của Zalo không có dữ liệu hợp lệ.',
    );
  }

  if (encryptType == 0) {
    return _decodeJson(rawData);
  }

  final encodedData = encryptType == 1 ? rawData : Uri.decodeComponent(rawData);
  final decodedBuffer = Uint8List.fromList(base64Decode(encodedData));

  Uint8List decryptedBuffer = decodedBuffer;
  if (encryptType != 1) {
    if (cipherKey == null || decodedBuffer.length < 48) {
      throw const ZaloLoginException(
        'Realtime payload cần cipher key nhưng hiện chưa có.',
      );
    }

    decryptedBuffer = _processAesGcm(
      key: Uint8List.fromList(base64Decode(cipherKey)),
      iv: decodedBuffer.sublist(0, 16),
      aad: decodedBuffer.sublist(16, 32),
      input: decodedBuffer.sublist(32),
      encryptMode: false,
    );
  }

  final payloadBytes = encryptType == 3
      ? decryptedBuffer
      : Uint8List.fromList(ZLibDecoder().convert(decryptedBuffer));
  return _decodeJson(utf8.decode(payloadBytes));
}

Uint8List _processAesGcm({
  required Uint8List key,
  required Uint8List iv,
  required Uint8List aad,
  required Uint8List input,
  required bool encryptMode,
}) {
  final cipher = GCMBlockCipher(AESEngine());
  cipher.init(encryptMode, AEADParameters(KeyParameter(key), 128, iv, aad));

  return Uint8List.fromList(cipher.process(input));
}

String _hexEncode(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }

  return buffer.toString();
}

_EvenOddCharacters _splitEvenOdd(String input) {
  final even = <String>[];
  final odd = <String>[];

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (index.isEven) {
      even.add(character);
    } else {
      odd.add(character);
    }
  }

  return _EvenOddCharacters(even: even, odd: odd);
}

String _defaultRandomString(int? minLength, int? maxLength) {
  const chars = '0123456789abcdef';
  final random = math.Random.secure();
  final min = minLength ?? 6;
  final max = maxLength != null && maxLength >= min ? maxLength : 12;
  final length = min + random.nextInt(max - min + 1);
  final buffer = StringBuffer();

  for (var index = 0; index < length; index++) {
    buffer.write(chars[random.nextInt(chars.length)]);
  }

  return buffer.toString();
}

Map<String, List<String>> _parseServiceMap(dynamic value) {
  final map = _asMap(value);
  return Map<String, List<String>>.unmodifiable(
    map.map(
      (key, item) =>
          MapEntry(key, List<String>.unmodifiable(_asStringList(item))),
    ),
  );
}

Map<String, dynamic> _decodeJson(String raw) {
  final decoded = jsonDecode(raw);

  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is Map) {
    return Map<String, dynamic>.from(decoded);
  }

  throw const FormatException('API response must be a JSON object.');
}

Object? _tryDecodeLogJson(String raw) {
  try {
    return jsonDecode(raw);
  } catch (_) {
    return raw;
  }
}

String _formatZaloLogValue(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is String) {
    return value;
  }

  try {
    return jsonEncode(value);
  } catch (_) {
    return value.toString();
  }
}

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }

  return const <String, dynamic>{};
}

List<String> _asStringList(dynamic value) {
  if (value is List<String>) {
    return List<String>.unmodifiable(value);
  }
  if (value is List) {
    return List<String>.unmodifiable(
      value
          .map((item) => item?.toString() ?? '')
          .where((item) => item.isNotEmpty),
    );
  }

  return const <String>[];
}

List<dynamic> _asDynamicList(dynamic value) {
  if (value is List<dynamic>) {
    return List<dynamic>.unmodifiable(value);
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(List<dynamic>.from(value));
  }

  return const <dynamic>[];
}

List<dynamic> _friendItemsFromResponseData(dynamic value) {
  if (value is List) {
    return _asDynamicList(value);
  }

  final data = _asMap(value);
  for (final key in const ['friends', 'items', 'users', 'list', 'data']) {
    final items = _asDynamicList(data[key]);
    if (items.isNotEmpty) {
      return items;
    }
  }

  return const <dynamic>[];
}

List<int> _asIntList(dynamic value) {
  return _asDynamicList(value).map(_asInt).toList(growable: false);
}

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }

  return int.tryParse(value?.toString() ?? '') ?? 0;
}
