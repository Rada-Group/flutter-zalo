import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'zalo_curl_interceptor.dart';
import 'zalo_logger.dart';
import 'zalo_models.dart';

class ZaloQrLoginService {
  ZaloQrLoginService({
    Dio? client,
    Future<String> Function(String userAgent)? imeiResolver,
    Future<String?> Function()? deviceCookieReader,
    Future<void> Function(String cookie)? deviceCookieWriter,
    Duration qrExpiresAfter = const Duration(seconds: 100),
  }) : _client = _buildHttpClient(client),
       _imeiResolver = imeiResolver ?? _defaultImeiResolver,
       _deviceCookieReader = deviceCookieReader,
       _deviceCookieWriter = deviceCookieWriter,
       _qrExpiresAfter = qrExpiresAfter;

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// Client hints suy ra trực tiếp từ [userAgent] (zca-js PR #303). `sec-ch-ua`
  /// và `sec-ch-ua-platform` PHẢI khớp Chrome version/OS trong User-Agent — nếu
  /// lệch, anti-bot của Zalo phát hiện fingerprint mismatch và ban session.
  static final String _secChUa =
      '"Chromium";v="${zaloChromeMajorVersion(userAgent)}", '
      '"Google Chrome";v="${zaloChromeMajorVersion(userAgent)}", '
      '"Not?A_Brand";v="99"';
  static final String _secChUaPlatform = '"${zaloSecChUaPlatform(userAgent)}"';

  /// Long-lived cookies Zalo uses to recognize a device across logins.
  ///
  /// `zpdid` (Zalo Persistent Device ID) is the one that drives the server's
  /// `isTrust` flag — replaying it lets a previously-confirmed device be
  /// trusted again instead of triggering the "đăng nhập từ thiết bị lạ" warning.
  /// `__zi`/`__zi-legacy`/`_zlang` are analytics/locale cookies kept for a
  /// consistent fingerprint.
  static const Set<String> _deviceCookieNames = <String>{
    'zpdid',
    '__zi',
    '__zi-legacy',
    '_zlang',
  };

  /// Domain the device cookies are scoped to, so they match both
  /// `id.zalo.me` and `chat.zalo.me` when replayed.
  static const String _deviceCookieSeedUrl = 'https://zalo.me/';

  static const _loginPageUrl =
      'https://id.zalo.me/account?continue=https%3A%2F%2Fchat.zalo.me%2F';
  static const _continueChat = 'https://chat.zalo.me/';
  // Bootstrap + QR generate dùng continue=zalo.me/pc giống hệt zca-js / các
  // reference đang chạy được. Trước đây ta dùng chat.zalo.me cho cả bootstrap
  // và Zalo phục vụ luồng QR "đa lớp" (enabledMultiLayer) khiến confirm trả
  // "Mã đăng nhập không hợp lệ". Scan + confirm vẫn giữ continue=chat.zalo.me.
  static const _continuePc = 'https://zalo.me/pc';
  static const _checkSessionUrl =
      'https://id.zalo.me/account/checksession'
      '?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html';
  static const _userInfoUrl = 'https://jr.chat.zalo.me/jr/userinfo';
  static const _chatHomeUrl = 'https://chat.zalo.me/';
  static const _logName = 'PAM.ZaloQR';

  /// Delay before re-polling after a transient network error, to avoid a hot loop.
  static const _pollRetryDelay = Duration(seconds: 2);

  final Dio _client;
  final Future<String> Function(String userAgent) _imeiResolver;
  final Future<String?> Function()? _deviceCookieReader;
  final Future<void> Function(String cookie)? _deviceCookieWriter;
  final Duration _qrExpiresAfter;
  final _ZaloCookieJar _cookieJar = _ZaloCookieJar();

  static Dio _buildHttpClient(Dio? client) {
    if (client != null) {
      return client;
    }

    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 110),
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

  Stream<ZaloQrLoginEvent> startLogin({CancelToken? cancelToken}) async* {
    _cookieJar.clear();
    await _seedDeviceCookies();
    zaloLog(
      'QR login started',
      name: _logName,
      data: {'qrTtlSec': _qrExpiresAfter.inSeconds},
    );
    yield const ZaloQrLoginEvent.generating();

    final expiresAt = DateTime.now().add(_qrExpiresAfter);
    final version = await _loadLoginVersion(cancelToken: cancelToken);
    zaloLog('Loaded login version', name: _logName, data: {'v': version});
    // The login-page load (re)sets the `__zi` device cookie; persist it now so
    // even an abandoned login seeds the next one as the same device.
    await _persistDeviceCookies();

    await _postForm(
      'https://id.zalo.me/account/logininfo',
      body: {'continue': _continuePc, 'v': version},
      cancelToken: cancelToken,
    );
    zaloLog('Completed logininfo bootstrap', name: _logName);

    await _postForm(
      'https://id.zalo.me/account/verify-client',
      body: {'type': 'device', 'continue': _continuePc, 'v': version},
      cancelToken: cancelToken,
    );
    zaloLog('Completed verify-client bootstrap', name: _logName);

    final generated = await _generateQr(
      version: version,
      cancelToken: cancelToken,
    );
    zaloLog(
      'Generated QR code',
      name: _logName,
      data: {
        'code': maskValue(generated.code),
        'bytes': generated.qrImageBytes.length,
      },
    );

    yield ZaloQrLoginEvent.qrGenerated(
      qrImageBytes: generated.qrImageBytes,
      qrCode: generated.code,
    );

    final scannedProfile = await _waitForScan(
      version: version,
      code: generated.code,
      expiresAt: expiresAt,
      cancelToken: cancelToken,
    );
    zaloLog(
      'QR scanned',
      name: _logName,
      data: {'profile': scannedProfile.displayName},
    );
    yield ZaloQrLoginEvent.scanned(profile: scannedProfile);

    // Confirm dùng mã generate gốc như mọi reference (zca-js/Elixir/Go). Mã
    // "xoay" mà luồng đa lớp trả về ở scan KHÔNG dùng cho confirm (đã thử,
    // vẫn bị "Mã đăng nhập không hợp lệ").
    await _waitForConfirm(
      version: version,
      code: generated.code,
      expiresAt: expiresAt,
      cancelToken: cancelToken,
    );
    zaloLog('QR confirmed on phone', name: _logName);
    yield const ZaloQrLoginEvent.confirmed();

    await _getPlain(_checkSessionUrl, cancelToken: cancelToken);
    final userInfo = await _getJson(
      _userInfoUrl,
      cancelToken: cancelToken,
      headers: {'Referer': _chatHomeUrl, 'sec-fetch-site': 'same-site'},
    );
    final profile = _profileFromUserInfo(userInfo);
    final imei = await _imeiResolver(userAgent);
    final credentials = ZaloCredentials(
      cookie: _cookieJar.cookieHeaderFor(_chatHomeUrl),
      imei: imei,
      userAgent: userAgent,
    );
    zaloLog(
      'QR login produced credentials',
      name: _logName,
      data: {
        'cookieNames': _cookieJar.cookieNamesFor(_chatHomeUrl),
        'cookieBytes': credentials.cookie.length,
        'imei': maskValue(credentials.imei, head: 8, tail: 8),
      },
    );
    await _persistDeviceCookies();

    yield ZaloQrLoginEvent.success(
      result: ZaloLoginResult(credentials: credentials, profile: profile),
    );
  }

  static Future<String> _defaultImeiResolver(String userAgent) async {
    return generateZaloImei(userAgent);
  }

  Future<void> _seedDeviceCookies() async {
    final reader = _deviceCookieReader;
    if (reader == null) {
      return;
    }

    final stored = await reader();
    if (stored == null || stored.isEmpty) {
      return;
    }

    _cookieJar.seed(Uri.parse(_deviceCookieSeedUrl), stored);
    zaloLog(
      'Replayed stored Zalo device cookies for QR login',
      name: _logName,
      data: {'cookieNames': _cookieJar.cookieNamesFor(_deviceCookieSeedUrl)},
    );
  }

  Future<void> _persistDeviceCookies() async {
    final writer = _deviceCookieWriter;
    if (writer == null) {
      return;
    }

    final header = _cookieJar.deviceCookieHeader(_deviceCookieNames);
    if (header.isEmpty) {
      return;
    }

    await writer(header);
  }

  Future<String> _loadLoginVersion({CancelToken? cancelToken}) async {
    final html = await _getPlain(_loginPageUrl, cancelToken: cancelToken);
    final version = extractZaloLoginVersion(html);

    if (version == null) {
      throw const ZaloLoginException(
        'Không lấy được phiên bản login Zalo để tạo QR.',
      );
    }

    return version;
  }

  Future<_GeneratedQrPayload> _generateQr({
    required String version,
    CancelToken? cancelToken,
  }) async {
    final response = await _postJson(
      'https://id.zalo.me/account/authen/qr/generate',
      body: {'continue': _continuePc, 'v': version},
      cancelToken: cancelToken,
    );

    final data = _asNullableMap(response['data']);
    final code = data?['code'] as String?;
    final image = data?['image'] as String?;

    if (code == null || code.isEmpty || image == null || image.isEmpty) {
      final errorCode = _asInt(response['error_code']);
      final errorMessage = response['error_message'] as String?;
      throw ZaloLoginException(
        errorMessage ??
            'Zalo không trả về dữ liệu QR hợp lệ (code $errorCode).',
      );
    }

    return _GeneratedQrPayload(
      code: code,
      qrImageBytes: decodeZaloQrImage(image),
    );
  }

  Future<ZaloProfile> _waitForScan({
    required String version,
    required String code,
    required DateTime expiresAt,
    CancelToken? cancelToken,
  }) async {
    var attempts = 0;
    while (true) {
      attempts += 1;
      Map<String, dynamic> response;
      try {
        response = await _postJson(
          'https://id.zalo.me/account/authen/qr/waiting-scan',
          body: {'code': code, 'continue': _continueChat, 'v': version},
          cancelToken: cancelToken,
        );
      } on DioException catch (error) {
        if (!_isTransientNetworkError(error)) {
          rethrow;
        }
        zaloLog(
          'Waiting scan hit transient network error, retrying',
          name: _logName,
          data: {'attempt': attempts, 'type': error.type.name},
        );
        // Only give up here if we're truly out of time — a request that
        // just failed transiently deserves one more try before that.
        _throwIfExpired(expiresAt);
        await Future<void>.delayed(_pollRetryDelay);
        continue;
      }

      final errorCode = _asInt(response['error_code']);
      if (attempts == 1 || attempts % 5 == 0 || errorCode != 8) {
        zaloLog(
          'Waiting scan response',
          name: _logName,
          data: {'attempt': attempts, 'errorCode': errorCode},
        );
      }
      if (errorCode == 8) {
        // "Still waiting" — a real server answer (success/decline/other
        // error) always takes priority over a locally-elapsed clock, so the
        // expiry check only happens once we know we have to loop again.
        _throwIfExpired(expiresAt);
        continue;
      }
      if (errorCode != 0) {
        final errorMessage = response['error_message'] as String?;
        throw ZaloLoginException(
          errorMessage ?? 'Không thể quét QR đăng nhập (code $errorCode).',
        );
      }

      final data = _asNullableMap(response['data']);
      if (data == null) {
        throw const ZaloLoginException('Không nhận được thông tin từ QR scan.');
      }

      // Chẩn đoán luồng "đa lớp" (enabledMultiLayer): luồng thường trả
      // {display_name, avatar}; luồng đa lớp trả status + chatUid + code/token/
      // image MỚI nhưng KHÔNG có display_name. Log lại để biết Zalo đang phục
      // vụ luồng nào. Confirm vẫn dùng mã generate gốc (xem startLogin).
      final scanCode = data['code'] as String?;
      zaloLog(
        'QR scan payload',
        name: _logName,
        data: {
          'status': data['status'],
          'hasDisplayName': data['display_name'] != null,
          'codeRotated':
              scanCode != null && scanCode.isNotEmpty && scanCode != code,
        },
      );

      return ZaloProfile(
        displayName: data['display_name'] as String? ?? 'Tài khoản Zalo',
        avatarUrl: data['avatar'] as String? ?? '',
      );
    }
  }

  Future<void> _waitForConfirm({
    required String version,
    required String code,
    required DateTime expiresAt,
    CancelToken? cancelToken,
  }) async {
    var attempts = 0;
    while (true) {
      attempts += 1;
      Map<String, dynamic> response;
      try {
        response = await _postJson(
          'https://id.zalo.me/account/authen/qr/waiting-confirm',
          body: {
            'code': code,
            'gToken': '',
            'gAction': 'CONFIRM_QR',
            'continue': _continueChat,
            'v': version,
          },
          cancelToken: cancelToken,
        );
      } on DioException catch (error) {
        if (!_isTransientNetworkError(error)) {
          rethrow;
        }
        zaloLog(
          'Waiting confirm hit transient network error, retrying',
          name: _logName,
          data: {'attempt': attempts, 'type': error.type.name},
        );
        _throwIfExpired(expiresAt);
        await Future<void>.delayed(_pollRetryDelay);
        continue;
      }

      final errorCode = _asInt(response['error_code']);
      if (attempts == 1 || attempts % 5 == 0 || errorCode != 8) {
        zaloLog(
          'Waiting confirm response',
          name: _logName,
          data: {'attempt': attempts, 'errorCode': errorCode},
        );
      }
      if (errorCode == 8) {
        _throwIfExpired(expiresAt);
        continue;
      }
      if (errorCode == -13) {
        throw const ZaloLoginDeclinedException(
          'Bạn đã từ chối đăng nhập trên điện thoại.',
        );
      }
      if (errorCode != 0) {
        final errorMessage = response['error_message'] as String?;
        throw ZaloLoginException(
          errorMessage ?? 'Không thể xác nhận QR đăng nhập.',
        );
      }

      return;
    }
  }

  Future<String> _getPlain(
    String url, {
    CancelToken? cancelToken,
    int redirectCount = 0,
    Map<String, String>? headers,
  }) async {
    final response = await _client.get<String>(
      url,
      cancelToken: cancelToken,
      options: Options(headers: _buildHeaders(url, headers: headers)),
    );

    _captureCookies(url, response);
    _logHttpResponse('GET', url, response);
    final redirectUrl = _redirectLocation(response);
    if (redirectUrl != null) {
      if (redirectCount >= 5) {
        throw const ZaloLoginException(
          'Zalo chuyển hướng quá nhiều lần khi kiểm tra phiên.',
        );
      }

      final nextUrl = _resolveRedirectUrl(url, redirectUrl);
      zaloLog(
        'Following Zalo QR redirect',
        name: _logName,
        data: {
          'from': Uri.tryParse(url)?.host ?? '',
          'to': Uri.tryParse(nextUrl)?.host ?? '',
        },
      );
      return _getPlain(
        nextUrl,
        cancelToken: cancelToken,
        redirectCount: redirectCount + 1,
        headers: {'Referer': 'https://id.zalo.me/'},
      );
    }

    _ensureSuccessStatus(response);
    return response.data ?? '';
  }

  Future<Map<String, dynamic>> _getJson(
    String url, {
    CancelToken? cancelToken,
    Map<String, String>? headers,
  }) async {
    final raw = await _getPlain(
      url,
      cancelToken: cancelToken,
      headers: headers,
    );
    final payload = _decodeJson(raw);
    _logApiPayload(url, payload);
    return payload;
  }

  Future<Response<String>> _postForm(
    String url, {
    required Map<String, String> body,
    CancelToken? cancelToken,
  }) async {
    final response = await _client.post<String>(
      url,
      data: body,
      cancelToken: cancelToken,
      options: Options(
        headers: _buildHeaders(url, isForm: true),
        contentType: Headers.formUrlEncodedContentType,
      ),
    );

    _captureCookies(url, response);
    _logHttpResponse('POST', url, response);
    _ensureSuccessStatus(response);
    return response;
  }

  Future<Map<String, dynamic>> _postJson(
    String url, {
    required Map<String, String> body,
    CancelToken? cancelToken,
  }) async {
    final response = await _postForm(url, body: body, cancelToken: cancelToken);
    final payload = _decodeJson(response.data ?? '{}');
    _logApiPayload(url, payload);
    return payload;
  }

  void _logHttpResponse(String method, String url, Response<String> response) {
    zaloLog(
      'Zalo QR HTTP response',
      name: _logName,
      data: {
        'method': method,
        'host': Uri.tryParse(url)?.host ?? '',
        'path': Uri.tryParse(url)?.path ?? url,
        'status': response.statusCode ?? 0,
        'cookieNames': _cookieJar.cookieNamesFor(url),
      },
    );
  }

  void _logApiPayload(String url, Map<String, dynamic> payload) {
    if (!payload.containsKey('error_code') && !payload.containsKey('data')) {
      return;
    }

    final logData = <String, Object?>{
      'path': Uri.tryParse(url)?.path ?? url,
      if (payload.containsKey('error_code'))
        'errorCode': _asInt(payload['error_code']),
    };
    if (payload['error_message'] != null) {
      logData['errorMessage'] = payload['error_message'];
    }
    final data = payload['data'];
    if (data is Map) {
      logData['dataKeys'] = data.keys.toList(growable: false);
      if (data.containsKey('logged')) {
        logData['logged'] = data['logged'];
      }
      if (data.containsKey('session_chat_valid')) {
        logData['sessionChatValid'] = data['session_chat_valid'];
      }
      if (data.containsKey('isTrust')) {
        logData['isTrust'] = data['isTrust'];
      }
    } else if (payload.containsKey('data')) {
      logData['dataType'] = data.runtimeType.toString();
    }

    zaloLog('Zalo QR API payload', name: _logName, data: logData);
  }

  String? _redirectLocation(Response<String> response) {
    final statusCode = response.statusCode ?? 0;
    if (statusCode < 300 || statusCode >= 400) {
      return null;
    }

    final locations = response.headers['location'];
    if (locations == null || locations.isEmpty) {
      return null;
    }

    final location = locations.first.trim();
    return location.isEmpty ? null : location;
  }

  String _resolveRedirectUrl(String currentUrl, String location) {
    final redirectUri = Uri.parse(location);
    if (redirectUri.hasScheme) {
      return redirectUri.toString();
    }

    return Uri.parse(currentUrl).resolveUri(redirectUri).toString();
  }

  Map<String, String> _buildHeaders(
    String url, {
    bool isForm = false,
    Map<String, String>? headers,
  }) {
    final cookie = _cookieJar.cookieHeaderFor(url);
    return <String, String>{
      'User-Agent': userAgent,
      'accept': '*/*',
      'accept-language': 'vi-VN,vi;q=0.9,en-US;q=0.8,en;q=0.7',
      'sec-ch-ua': _secChUa,
      'sec-ch-ua-mobile': '?0',
      'sec-ch-ua-platform': _secChUaPlatform,
      'sec-fetch-dest': 'empty',
      'sec-fetch-mode': 'cors',
      'sec-fetch-site': 'same-origin',
      'priority': 'u=1, i',
      'Referer': _loginPageUrl,
      if (isForm) ...{
        'Content-Type': Headers.formUrlEncodedContentType,
        'Origin': 'https://id.zalo.me',
      },
      if (cookie.isNotEmpty) 'Cookie': cookie,
      ...?headers,
    };
  }

  void _captureCookies(String url, Response<String> response) {
    _cookieJar.merge(
      Uri.parse(url),
      response.headers['set-cookie'] ?? const <String>[],
    );
  }

  void _ensureSuccessStatus(Response<String> response) {
    final statusCode = response.statusCode ?? 0;
    if (statusCode >= 200 && statusCode < 400) {
      return;
    }

    throw ZaloLoginException('Yêu cầu tới Zalo thất bại với mã $statusCode.');
  }

  void _throwIfExpired(DateTime expiresAt) {
    if (DateTime.now().isAfter(expiresAt)) {
      throw const ZaloQrExpiredException('Mã QR đã hết hạn. Vui lòng tạo lại.');
    }
  }

  /// True for transport hiccups (incl. the socket abort backgrounding the app
  /// mid-poll causes) that should retry the poll instead of failing the login.
  bool _isTransientNetworkError(DioException error) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return true;
      case DioExceptionType.unknown:
        return error.error is SocketException || error.error is HttpException;
      // cancel, badCertificate, badResponse, transformTimeout (dio >=5.10) và
      // mọi enum mới khác đều coi là lỗi không nên retry.
      default:
        return false;
    }
  }
}

/// Suy ra giá trị `sec-ch-ua-platform` từ User-Agent (zca-js PR #303).
///
/// Header platform PHẢI khớp OS trong User-Agent, nếu không anti-bot của Zalo
/// phát hiện fingerprint mismatch và ban session. Thứ tự: Windows → macOS →
/// Linux → fallback "Windows" (an toàn nhất).
String zaloSecChUaPlatform(String userAgent) {
  if (RegExp('Windows', caseSensitive: false).hasMatch(userAgent)) {
    return 'Windows';
  }
  if (RegExp('Macintosh|Mac OS X', caseSensitive: false).hasMatch(userAgent)) {
    return 'macOS';
  }
  if (RegExp('Linux|X11', caseSensitive: false).hasMatch(userAgent)) {
    return 'Linux';
  }
  return 'Windows';
}

/// Trích xuất Chrome major version từ User-Agent (zca-js PR #303), dùng để điền
/// `sec-ch-ua` cho khớp UA. Fallback "130" nếu UA không phải Chrome/Chromium.
String zaloChromeMajorVersion(String userAgent) {
  final match = RegExp(r'Chrome/(\d+)').firstMatch(userAgent);
  return match?.group(1) ?? '130';
}

String? extractZaloLoginVersion(String html) {
  final match = RegExp(
    r'https:\/\/stc-zlogin\.zdn\.vn\/main-([\d.]+)\.js',
  ).firstMatch(html);
  return match?.group(1);
}

void mergeZaloSetCookieHeaders(
  Map<String, String> cookies,
  Iterable<String> setCookieHeaders,
) {
  for (final header in setCookieHeaders) {
    for (final cookieHeader in splitZaloSetCookieHeader(header)) {
      final segments = cookieHeader.split(';');
      if (segments.isEmpty) {
        continue;
      }

      final pair = segments.first;
      final separator = pair.indexOf('=');
      if (separator <= 0) {
        continue;
      }

      final key = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();

      if (key.isEmpty || value.isEmpty) {
        continue;
      }

      cookies[key] = value;
    }
  }
}

Iterable<String> splitZaloSetCookieHeader(String header) sync* {
  var start = 0;

  for (var index = 0; index < header.length; index++) {
    if (header.codeUnitAt(index) != 44) {
      continue;
    }

    final rest = header.substring(index + 1);
    if (RegExp(r'^\s*[^=;,\s]+=').hasMatch(rest)) {
      final cookie = header.substring(start, index).trim();
      if (cookie.isNotEmpty) {
        yield cookie;
      }
      start = index + 1;
    }
  }

  final lastCookie = header.substring(start).trim();
  if (lastCookie.isNotEmpty) {
    yield lastCookie;
  }
}

String serializeZaloCookies(Map<String, String> cookies) {
  return cookies.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');
}

class _ZaloCookieJar {
  final List<_ZaloCookie> _cookies = <_ZaloCookie>[];

  void clear() {
    _cookies.clear();
  }

  void merge(Uri responseUri, Iterable<String> setCookieHeaders) {
    for (final header in setCookieHeaders) {
      for (final cookieHeader in splitZaloSetCookieHeader(header)) {
        final cookie = _ZaloCookie.parse(cookieHeader, responseUri);
        if (cookie == null) {
          continue;
        }

        _cookies.removeWhere(
          (current) =>
              current.name == cookie.name &&
              current.domain == cookie.domain &&
              current.path == cookie.path,
        );

        if (!cookie.isExpired) {
          _cookies.add(cookie);
        }
      }
    }
  }

  /// Pre-loads device-identity cookies (e.g. `__zi`) from a previously stored
  /// `name=value; name=value` header so the next QR login looks like the same
  /// device to Zalo. Seeded cookies use a shared parent domain and `/` path so
  /// they match both `id.zalo.me` and `chat.zalo.me`.
  void seed(Uri domainUri, String cookieHeader) {
    final domain = domainUri.host.toLowerCase().replaceFirst(RegExp(r'^\.'), '');
    if (domain.isEmpty) {
      return;
    }

    for (final segment in cookieHeader.split(';')) {
      final pair = segment.trim();
      if (pair.isEmpty) {
        continue;
      }

      final separator = pair.indexOf('=');
      if (separator <= 0) {
        continue;
      }

      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (name.isEmpty || value.isEmpty) {
        continue;
      }

      _cookies.removeWhere(
        (current) => current.name == name && current.domain == domain,
      );
      _cookies.add(
        _ZaloCookie(
          name: name,
          value: value,
          domain: domain,
          hostOnly: false,
          path: '/',
          isExpired: false,
        ),
      );
    }
  }

  String cookieHeaderFor(String url) {
    final uri = Uri.parse(url);
    final matching = _cookies.where((cookie) => cookie.matches(uri)).toList()
      ..sort((left, right) => right.path.length.compareTo(left.path.length));

    return matching
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// Serializes the long-lived device-identity cookies (by [names]) into a
  /// `name=value; name=value` header for persistence between logins.
  String deviceCookieHeader(Set<String> names) {
    return _cookies
        .where((cookie) => names.contains(cookie.name) && !cookie.isExpired)
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  List<String> cookieNamesFor(String url) {
    final uri = Uri.parse(url);
    return _cookies
        .where((cookie) => cookie.matches(uri))
        .map((cookie) => cookie.name)
        .toList(growable: false);
  }
}

class _ZaloCookie {
  const _ZaloCookie({
    required this.name,
    required this.value,
    required this.domain,
    required this.hostOnly,
    required this.path,
    required this.isExpired,
  });

  final String name;
  final String value;
  final String domain;
  final bool hostOnly;
  final String path;
  final bool isExpired;

  static _ZaloCookie? parse(String header, Uri responseUri) {
    final segments = header
        .split(';')
        .map((segment) => segment.trim())
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return null;
    }

    final pair = segments.first;
    final separator = pair.indexOf('=');
    if (separator <= 0) {
      return null;
    }

    final name = pair.substring(0, separator).trim();
    final value = pair.substring(separator + 1).trim();
    if (name.isEmpty) {
      return null;
    }

    var domain = responseUri.host.toLowerCase();
    var hostOnly = true;
    var path = '/';
    var isExpired = value.isEmpty;

    for (final attribute in segments.skip(1)) {
      final attributeSeparator = attribute.indexOf('=');
      final attributeName =
          (attributeSeparator == -1
                  ? attribute
                  : attribute.substring(0, attributeSeparator))
              .trim()
              .toLowerCase();
      final attributeValue = attributeSeparator == -1
          ? ''
          : attribute.substring(attributeSeparator + 1).trim();

      switch (attributeName) {
        case 'domain':
          final normalizedDomain = attributeValue.toLowerCase().replaceFirst(
            RegExp(r'^\.'),
            '',
          );
          if (normalizedDomain.isNotEmpty) {
            domain = normalizedDomain;
            hostOnly = false;
          }
        case 'path':
          if (attributeValue.startsWith('/')) {
            path = attributeValue;
          }
        case 'max-age':
          if (int.tryParse(attributeValue) == 0) {
            isExpired = true;
          }
        case 'expires':
          final expiresAt = _tryParseHttpDate(attributeValue);
          if (expiresAt != null && expiresAt.isBefore(DateTime.now())) {
            isExpired = true;
          }
      }
    }

    return _ZaloCookie(
      name: name,
      value: value,
      domain: domain,
      hostOnly: hostOnly,
      path: path,
      isExpired: isExpired,
    );
  }

  bool matches(Uri uri) {
    final host = uri.host.toLowerCase();
    final requestPath = uri.path.isEmpty ? '/' : uri.path;
    final domainMatches = hostOnly
        ? host == domain
        : host == domain || host.endsWith('.$domain');

    return domainMatches && requestPath.startsWith(path);
  }
}

DateTime? _tryParseHttpDate(String value) {
  final trimmed = value.trim();
  try {
    return HttpDate.parse(trimmed);
  } on FormatException {
    return _tryParseZaloCookieDate(trimmed);
  } on HttpException {
    return _tryParseZaloCookieDate(trimmed);
  }
}

DateTime? _tryParseZaloCookieDate(String value) {
  final match = RegExp(
    r'^[A-Za-z]{3},\s*(\d{1,2})-([A-Za-z]{3})-(\d{2,4})\s+'
    r'(\d{1,2}):(\d{2}):(\d{2})\s+GMT$',
    caseSensitive: false,
  ).firstMatch(value);
  if (match == null) {
    return null;
  }

  final day = int.tryParse(match.group(1)!);
  final month = _monthNumber(match.group(2)!);
  var year = int.tryParse(match.group(3)!);
  final hour = int.tryParse(match.group(4)!);
  final minute = int.tryParse(match.group(5)!);
  final second = int.tryParse(match.group(6)!);
  if (day == null ||
      month == null ||
      year == null ||
      hour == null ||
      minute == null ||
      second == null) {
    return null;
  }

  if (year < 100) {
    year += year >= 70 ? 1900 : 2000;
  }

  final parsed = DateTime.utc(year, month, day, hour, minute, second);
  if (parsed.year != year ||
      parsed.month != month ||
      parsed.day != day ||
      parsed.hour != hour ||
      parsed.minute != minute ||
      parsed.second != second) {
    return null;
  }

  return parsed;
}

int? _monthNumber(String month) {
  return const <String, int>{
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  }[month.toLowerCase()];
}

Uint8List decodeZaloQrImage(String imageData) {
  final base64Payload = imageData.replaceFirst('data:image/png;base64,', '');
  return base64Decode(base64Payload);
}

String generateZaloImei(String userAgent, {Random? random}) {
  final uuid = _generateUuidV4(random ?? Random.secure());
  final userAgentHash = md5.convert(utf8.encode(userAgent)).toString();
  return '$uuid-$userAgentHash';
}

/// Resolves a stable, per-device IMEI for Zalo.
///
/// Pass the individual storage callbacks instead of the full SecureStorageService
/// so this function has no dependency on the host app's storage layer.
///
/// * [readDeviceImei] — reads the persisted device IMEI (returns `null` if absent)
/// * [readSessionImei] — reads the current session IMEI (returns `null` if absent)
/// * [saveDeviceImei] — persists the resolved device IMEI
Future<String> resolveStableZaloImei(
  String userAgent, {
  required Future<String?> Function() readDeviceImei,
  required Future<String?> Function() readSessionImei,
  required Future<void> Function(String imei) saveDeviceImei,
}) async {
  final storedDeviceImei = await readDeviceImei();
  if (isCompatibleZaloImei(storedDeviceImei, userAgent)) {
    return storedDeviceImei!;
  }

  final sessionImei = await readSessionImei();
  if (isCompatibleZaloImei(sessionImei, userAgent)) {
    await saveDeviceImei(sessionImei!);
    return sessionImei;
  }

  final imei = generateZaloImei(userAgent);
  await saveDeviceImei(imei);
  return imei;
}

bool isCompatibleZaloImei(String? imei, String userAgent) {
  if (imei == null || imei.isEmpty) {
    return false;
  }

  final userAgentHash = md5.convert(utf8.encode(userAgent)).toString();
  return RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-'
        r'[0-9a-f]{12}-[0-9a-f]{32}$',
      ).hasMatch(imei) &&
      imei.endsWith('-$userAgentHash');
}

ZaloProfile _profileFromUserInfo(Map<String, dynamic> payload) {
  final data = _asNullableMap(payload['data']);
  if (data == null) {
    final errorCode = _asInt(payload['error_code']);
    final errorMessage = payload['error_message'] as String?;
    throw ZaloLoginException(
      errorMessage?.isNotEmpty == true
          ? errorMessage!
          : 'Zalo chưa trả về thông tin tài khoản sau QR (code $errorCode).',
    );
  }

  final logged = data['logged'] as bool? ?? false;
  if (!logged) {
    throw const ZaloLoginException(
      'Zalo chưa xác nhận phiên đăng nhập sau QR. Vui lòng thử lại.',
    );
  }

  return ZaloProfile.fromUserInfoJson(payload);
}

String _generateUuidV4(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;

  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

  return <String>[
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20),
  ].join('-');
}

String zaloErrorMessage(Object error) {
  if (error is ZaloLoginException) {
    return error.message;
  }
  if (error is DioException && error.type == DioExceptionType.cancel) {
    return 'Đã hủy kết nối Zalo.';
  }
  if (error is DioException &&
      (error.type == DioExceptionType.connectionError ||
          error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout)) {
    return 'Không thể kết nối tới Zalo. Vui lòng kiểm tra mạng.';
  }

  return 'Không thể kết nối Zalo lúc này. Vui lòng thử lại.';
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

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  throw const FormatException('API response must be a JSON object.');
}

Map<String, dynamic>? _asNullableMap(dynamic value) {
  if (value == null) {
    return null;
  }
  return _asMap(value);
}

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? -1;
}

class ZaloLoginException implements Exception {
  const ZaloLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ZaloQrExpiredException extends ZaloLoginException {
  const ZaloQrExpiredException(super.message);
}

class ZaloLoginDeclinedException extends ZaloLoginException {
  const ZaloLoginDeclinedException(super.message);
}

class _GeneratedQrPayload {
  const _GeneratedQrPayload({required this.code, required this.qrImageBytes});

  final String code;
  final Uint8List qrImageBytes;
}
