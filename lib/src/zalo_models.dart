import 'dart:convert';
import 'dart:typed_data';

typedef StoredZaloCredentials = ({
  String cookie,
  String imei,
  String userAgent,
});

class ZaloCredentials {
  const ZaloCredentials({
    required this.cookie,
    required this.imei,
    required this.userAgent,
  });

  final String cookie;
  final String imei;
  final String userAgent;

  StoredZaloCredentials toStorageRecord() {
    return (cookie: cookie, imei: imei, userAgent: userAgent);
  }

  factory ZaloCredentials.fromStorageRecord(StoredZaloCredentials record) {
    return ZaloCredentials(
      cookie: record.cookie,
      imei: record.imei,
      userAgent: record.userAgent,
    );
  }
}

class ZaloProfile {
  const ZaloProfile({
    required this.displayName,
    required this.avatarUrl,
    this.sessionChatValid = true,
  });

  final String displayName;
  final String avatarUrl;
  final bool sessionChatValid;

  factory ZaloProfile.fromUserInfoJson(Map<String, dynamic> json) {
    final data = _asMap(json['data']);
    final info = _asMap(data['info']);

    return ZaloProfile(
      displayName: info['name'] as String? ?? 'Tài khoản Zalo',
      avatarUrl: info['avatar'] as String? ?? '',
      sessionChatValid: data['session_chat_valid'] as bool? ?? true,
    );
  }

  factory ZaloProfile.fromProfileJson(Map<String, dynamic> json) {
    final profile = _asMap(json['profile']);

    return ZaloProfile(
      displayName:
          profile['displayName'] as String? ??
          profile['zaloName'] as String? ??
          profile['username'] as String? ??
          'Tài khoản Zalo',
      avatarUrl: profile['avatar'] as String? ?? '',
    );
  }
}

class ZaloFriend {
  const ZaloFriend({
    required this.userId,
    required this.displayName,
    required this.zaloName,
    required this.username,
    required this.avatarUrl,
    required this.phoneNumber,
    required this.isFriend,
    required this.lastActionTime,
    required this.lastUpdateTime,
  });

  factory ZaloFriend.fromJson(Map<String, dynamic> json) {
    final userId = _stringValue(
      _pickValue(json, const ['userId', 'uid', 'id']),
    );
    final displayName = _stringValue(
      _pickValue(json, const ['displayName', 'display_name']),
    );
    final zaloName = _stringValue(
      _pickValue(json, const ['zaloName', 'zalo_name']),
    );
    final username = _stringValue(_pickValue(json, const ['username']));
    final fallbackName = displayName.isNotEmpty
        ? displayName
        : zaloName.isNotEmpty
        ? zaloName
        : username.isNotEmpty
        ? username
        : userId;

    return ZaloFriend(
      userId: userId,
      displayName: fallbackName,
      zaloName: zaloName,
      username: username,
      avatarUrl: _nullableString(
        _pickValue(json, const ['avatar', 'avatarUrl', 'avatar_url']),
      ),
      phoneNumber: _nullableString(
        _pickValue(json, const ['phoneNumber', 'phone_number']),
      ),
      isFriend: _asInt(_pickValue(json, const ['isFr', 'is_friend'])) != 0,
      lastActionTime: _asInt(
        _pickValue(json, const ['lastActionTime', 'last_action_time']),
      ),
      lastUpdateTime: _asInt(
        _pickValue(json, const ['lastUpdateTime', 'last_update_time']),
      ),
    );
  }

  final String userId;
  final String displayName;
  final String zaloName;
  final String username;
  final String? avatarUrl;
  final String? phoneNumber;
  final bool isFriend;
  final int lastActionTime;
  final int lastUpdateTime;
}

class ZaloLoginResult {
  const ZaloLoginResult({required this.credentials, required this.profile});

  final ZaloCredentials credentials;
  final ZaloProfile profile;
}

class ZaloConnectionSnapshot {
  ZaloConnectionSnapshot({
    required this.credentials,
    required this.profile,
    required ZaloSessionInfo session,
  }) : session = session.freeze();

  final ZaloCredentials credentials;
  final ZaloProfile profile;
  final ZaloSessionInfo session;
}

class ZaloSessionInfo {
  ZaloSessionInfo({
    required this.userId,
    required this.secretKey,
    required Map<String, List<String>> serviceMap,
    required List<String> wsUrls,
    required Map<String, dynamic> settings,
    required Map<String, dynamic> extraVersions,
  }) : serviceMap = Map.unmodifiable(
         serviceMap.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       wsUrls = List<String>.unmodifiable(wsUrls),
       settings = Map.unmodifiable(_deepFreezeMap(settings)),
       extraVersions = Map.unmodifiable(_deepFreezeMap(extraVersions));

  final String userId;
  final String secretKey;
  final Map<String, List<String>> serviceMap;
  final List<String> wsUrls;
  final Map<String, dynamic> settings;
  final Map<String, dynamic> extraVersions;

  ZaloSessionInfo freeze() {
    return ZaloSessionInfo(
      userId: userId,
      secretKey: secretKey,
      serviceMap: serviceMap,
      wsUrls: wsUrls,
      settings: settings,
      extraVersions: extraVersions,
    );
  }
}

class ZaloGroup {
  const ZaloGroup({
    required this.groupId,
    required this.name,
    required this.description,
    required this.memberCount,
    required this.maxMemberCount,
    required this.avatarUrl,
    required this.version,
    required this.isCommunity,
    this.creatorId,
  });

  factory ZaloGroup.fromInfo(ZaloGroupInfo info, {String version = ''}) {
    return ZaloGroup(
      groupId: info.groupId,
      name: info.name,
      description: info.description,
      memberCount: info.totalMember,
      maxMemberCount: info.maxMember,
      avatarUrl: info.avatarUrl,
      version: version,
      isCommunity: info.isCommunity,
      creatorId: info.creatorId.isEmpty ? null : info.creatorId,
    );
  }

  final String groupId;
  final String name;
  final String description;
  final int memberCount;
  final int maxMemberCount;
  final String? avatarUrl;
  final String version;
  final bool isCommunity;
  final String? creatorId;
}

class ZaloGroupCatalogEntry {
  const ZaloGroupCatalogEntry({
    required this.serverId,
    required this.zaloGroupId,
    required this.name,
    required this.description,
    required this.memberCount,
    required this.maxMemberCount,
    required this.avatarUrl,
    required this.creatorId,
    required this.version,
    required this.isCommunity,
    required this.region,
    required this.provinces,
    required this.priority,
    required this.isActive,
  });

  factory ZaloGroupCatalogEntry.fromJson(Map<String, dynamic> json) {
    final type = _asInt(_pickValue(json, const ['type']));
    final priorityValue = _pickValue(json, const ['priority']);

    return ZaloGroupCatalogEntry(
      serverId: _nullableString(_pickValue(json, const ['id'])),
      zaloGroupId: _stringValue(
        _pickValue(json, const [
          'zalo_group_id',
          'zaloGroupId',
          'group_id',
          'groupId',
        ]),
      ),
      name: _stringValue(
        _pickValue(json, const ['name']),
        fallback: 'Nhóm Zalo',
      ),
      description: _stringValue(
        _pickValue(json, const ['description', 'desc']),
      ),
      memberCount: _asInt(
        _pickValue(json, const ['member_count', 'memberCount']),
      ),
      maxMemberCount: _asInt(
        _pickValue(json, const ['max_member_count', 'maxMemberCount']),
      ),
      avatarUrl: _nullableString(
        _pickValue(json, const ['avatar_url', 'avatarUrl', 'avatar', 'avt']),
      ),
      creatorId: _nullableString(
        _pickValue(json, const ['creator_id', 'creatorId']),
      ),
      version: _stringValue(_pickValue(json, const ['version'])),
      isCommunity: _boolValue(
        _pickValue(json, const ['is_community', 'isCommunity']),
        fallback: type == 2,
      ),
      region: _nullableString(_pickValue(json, const ['region'])),
      provinces: _asStringList(_pickValue(json, const ['provinces'])),
      priority: priorityValue == null ? 5 : _asInt(priorityValue),
      isActive: _boolValue(
        _pickValue(json, const ['is_active', 'isActive']),
        fallback: true,
      ),
    );
  }

  factory ZaloGroupCatalogEntry.fromLocalGroup(ZaloGroup group) {
    return ZaloGroupCatalogEntry(
      serverId: null,
      zaloGroupId: group.groupId,
      name: group.name,
      description: group.description,
      memberCount: group.memberCount,
      maxMemberCount: group.maxMemberCount,
      avatarUrl: group.avatarUrl,
      creatorId: group.creatorId,
      version: group.version,
      isCommunity: group.isCommunity,
      region: null,
      provinces: const <String>[],
      priority: 5,
      isActive: true,
    );
  }

  final String? serverId;
  final String zaloGroupId;
  final String name;
  final String description;
  final int memberCount;
  final int maxMemberCount;
  final String? avatarUrl;
  final String? creatorId;
  final String version;
  final bool isCommunity;
  final String? region;
  final List<String> provinces;
  final int priority;
  final bool isActive;

  ZaloGroupCatalogEntry mergeLocalGroup(ZaloGroup group) {
    return copyWith(
      name: name.trim().isEmpty ? group.name : name,
      description: description.trim().isEmpty ? group.description : description,
      memberCount: memberCount > 0 ? memberCount : group.memberCount,
      maxMemberCount: maxMemberCount > 0
          ? maxMemberCount
          : group.maxMemberCount,
      avatarUrl: avatarUrl == null || avatarUrl!.trim().isEmpty
          ? group.avatarUrl
          : avatarUrl,
      creatorId: creatorId == null || creatorId!.trim().isEmpty
          ? group.creatorId
          : creatorId,
      version: version.isNotEmpty ? version : group.version,
      isCommunity: isCommunity || group.isCommunity,
    );
  }

  ZaloGroupCatalogEntry copyWith({
    String? serverId,
    String? zaloGroupId,
    String? name,
    String? description,
    int? memberCount,
    int? maxMemberCount,
    String? avatarUrl,
    bool clearAvatarUrl = false,
    String? creatorId,
    bool clearCreatorId = false,
    String? version,
    bool? isCommunity,
    String? region,
    bool clearRegion = false,
    List<String>? provinces,
    int? priority,
    bool? isActive,
  }) {
    return ZaloGroupCatalogEntry(
      serverId: serverId ?? this.serverId,
      zaloGroupId: zaloGroupId ?? this.zaloGroupId,
      name: name ?? this.name,
      description: description ?? this.description,
      memberCount: memberCount ?? this.memberCount,
      maxMemberCount: maxMemberCount ?? this.maxMemberCount,
      avatarUrl: clearAvatarUrl ? null : avatarUrl ?? this.avatarUrl,
      creatorId: clearCreatorId ? null : creatorId ?? this.creatorId,
      version: version ?? this.version,
      isCommunity: isCommunity ?? this.isCommunity,
      region: clearRegion ? null : region ?? this.region,
      provinces: List<String>.unmodifiable(provinces ?? this.provinces),
      priority: priority ?? this.priority,
      isActive: isActive ?? this.isActive,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      if (serverId != null && serverId!.trim().isNotEmpty) 'id': serverId,
      'zalo_group_id': zaloGroupId,
      'name': name,
      'description': description,
      'member_count': memberCount,
      'max_member_count': maxMemberCount,
      if (avatarUrl != null && avatarUrl!.trim().isNotEmpty)
        'avatar_url': avatarUrl,
      if (creatorId != null && creatorId!.trim().isNotEmpty)
        'creator_id': creatorId,
      'version': version,
      'is_community': isCommunity,
      if (region != null && region!.trim().isNotEmpty) 'region': region,
      'provinces': provinces.toList(growable: false),
      'priority': priority,
      'is_active': isActive,
    };
  }
}

class ZaloGroupCatalogSyncResult {
  const ZaloGroupCatalogSyncResult({
    required this.synced,
    required this.created,
    required this.updated,
    required this.groups,
  });

  factory ZaloGroupCatalogSyncResult.fromJson(Map<String, dynamic> json) {
    return ZaloGroupCatalogSyncResult(
      synced: _asInt(_pickValue(json, const ['synced'])),
      created: _asInt(_pickValue(json, const ['created'])),
      updated: _asInt(_pickValue(json, const ['updated'])),
      groups: _asDynamicList(_pickValue(json, const ['groups']))
          .map((item) => ZaloGroupCatalogEntry.fromJson(_asMap(item)))
          .toList(growable: false),
    );
  }

  final int synced;
  final int created;
  final int updated;
  final List<ZaloGroupCatalogEntry> groups;
}

class ZaloGroupInfo {
  const ZaloGroupInfo({
    required this.groupId,
    required this.name,
    required this.description,
    required this.type,
    required this.creatorId,
    required this.memberIds,
    required this.adminIds,
    required this.totalMember,
    required this.maxMember,
    required this.avatarUrl,
    required this.setting,
    required this.isE2EE,
  });

  factory ZaloGroupInfo.fromJson(Map<String, dynamic> json) {
    return ZaloGroupInfo(
      groupId: json['groupId'] as String? ?? '',
      name: json['name'] as String? ?? 'Nhóm Zalo',
      description: json['desc'] as String? ?? '',
      type: _asInt(json['type']),
      creatorId: json['creatorId'] as String? ?? '',
      memberIds: _asStringList(json['memberIds']),
      adminIds: _asStringList(json['adminIds']),
      totalMember: _asInt(json['totalMember']),
      maxMember: _asInt(json['maxMember']),
      avatarUrl: json['avt'] as String? ?? json['avatar'] as String?,
      setting: ZaloGroupSetting.fromJson(_asNullableMap(json['setting'])),
      isE2EE: _asInt(json['e2ee']) == 1,
    );
  }

  final String groupId;
  final String name;
  final String description;
  final int type;
  final String creatorId;
  final List<String> memberIds;
  final List<String> adminIds;
  final int totalMember;
  final int maxMember;
  final String? avatarUrl;
  final ZaloGroupSetting setting;
  final bool isE2EE;

  bool get isCommunity => type == 2;
}

class ZaloGroupSetting {
  const ZaloGroupSetting({
    required this.blockName,
    required this.signAdminMessage,
    required this.addMemberOnly,
    required this.lockSendMessage,
  });

  factory ZaloGroupSetting.fromJson(Map<String, dynamic>? json) {
    final data = json ?? const <String, dynamic>{};

    return ZaloGroupSetting(
      blockName: _asInt(data['blockName']),
      signAdminMessage: _asInt(data['signAdminMsg']),
      addMemberOnly: _asInt(data['addMemberOnly']),
      lockSendMessage: _asInt(data['lockSendMsg']),
    );
  }

  final int blockName;
  final int signAdminMessage;
  final int addMemberOnly;
  final int lockSendMessage;
}

enum ZaloThreadType { user, group }

class ZaloMention {
  const ZaloMention({
    required this.uid,
    required this.position,
    required this.length,
    required this.type,
  });

  factory ZaloMention.fromJson(Map<String, dynamic> json) {
    return ZaloMention(
      uid: json['uid'] as String? ?? '',
      position: _asInt(json['pos']),
      length: _asInt(json['len']),
      type: _asInt(json['type']),
    );
  }

  final String uid;
  final int position;
  final int length;
  final int type;
}

class ZaloQuote {
  const ZaloQuote({
    required this.ownerId,
    required this.ownerName,
    required this.msgId,
    required this.cliMsgId,
    required this.msgType,
    required this.timestamp,
    required this.content,
    required this.ttl,
    this.propertyExt,
    this.attach,
  });

  factory ZaloQuote.fromJson(Map<String, dynamic> json) {
    final attach = _nullableString(
      _pickValue(json, const ['attach', 'qmsgAttach']),
    );
    return ZaloQuote(
      ownerId: _stringValue(
        _pickValue(json, const ['ownerId', 'qmsgOwner', 'uidFrom']),
      ),
      ownerName: _stringValue(
        _pickValue(json, const ['ownerName', 'fromD', 'dName', 'displayName']),
      ),
      msgId: _stringValue(
        _pickValue(json, const ['msgId', 'globalMsgId', 'qmsgId']),
      ),
      cliMsgId: _stringValue(_pickValue(json, const ['cliMsgId', 'qmsgCliId'])),
      msgType:
          _nullableString(json['msgType']) ??
          _messageTypeFromClient(
            _pickValue(json, const ['cliMsgType', 'qmsgType']),
          ),
      timestamp: _stringValue(
        _pickValue(json, const ['ts', 'qmsgTs', 'timestamp']),
      ),
      content: _pickValue(json, const ['msg', 'qmsg', 'content']),
      ttl: _asInt(_pickValue(json, const ['ttl', 'qmsgTTL'])),
      propertyExt:
          _asNullableMap(json['propertyExt']) ?? _decodeJsonMap(attach),
      attach: attach,
    );
  }

  final String ownerId;
  final String ownerName;
  final String msgId;
  final String cliMsgId;
  final String msgType;
  final String timestamp;
  final Object? content;
  final int ttl;
  final Map<String, dynamic>? propertyExt;
  final String? attach;
}

class ZaloMessage {
  const ZaloMessage({
    required this.threadType,
    required this.msgId,
    required this.cliMsgId,
    required this.threadId,
    required this.senderUid,
    required this.senderName,
    required this.timestamp,
    required this.content,
    required this.msgType,
    required this.isSelf,
    required this.mentions,
    required this.quote,
    this.propertyExt,
  });

  factory ZaloMessage.fromGroup(String uid, Map<String, dynamic> raw) {
    final isSelf = raw['uidFrom']?.toString() == '0';
    return ZaloMessage(
      threadType: ZaloThreadType.group,
      msgId: raw['msgId']?.toString() ?? '',
      cliMsgId: raw['cliMsgId']?.toString(),
      threadId: raw['idTo']?.toString() ?? '',
      senderUid: isSelf ? uid : raw['uidFrom']?.toString() ?? '',
      senderName: raw['dName'] as String? ?? '',
      timestamp: raw['ts']?.toString() ?? '',
      content: raw['content'],
      msgType: raw['msgType'] as String? ?? '',
      isSelf: isSelf,
      mentions: _asDynamicList(
        raw['mentions'],
      ).map((item) => ZaloMention.fromJson(_asMap(item))).toList(),
      quote: _asNullableMap(raw['quote']) == null
          ? null
          : ZaloQuote.fromJson(_asMap(raw['quote'])),
      propertyExt: _asNullableMap(raw['propertyExt']),
    );
  }

  factory ZaloMessage.fromUser(String uid, Map<String, dynamic> raw) {
    final isSelf = raw['uidFrom']?.toString() == '0';
    return ZaloMessage(
      threadType: ZaloThreadType.user,
      msgId: raw['msgId']?.toString() ?? '',
      cliMsgId: raw['cliMsgId']?.toString(),
      threadId: isSelf
          ? raw['idTo']?.toString() ?? ''
          : raw['uidFrom']?.toString() ?? '',
      senderUid: isSelf ? uid : raw['uidFrom']?.toString() ?? '',
      senderName: raw['dName'] as String? ?? '',
      timestamp: raw['ts']?.toString() ?? '',
      content: raw['content'],
      msgType: raw['msgType'] as String? ?? '',
      isSelf: isSelf,
      mentions: const <ZaloMention>[],
      quote: _asNullableMap(raw['quote']) == null
          ? null
          : ZaloQuote.fromJson(_asMap(raw['quote'])),
      propertyExt: _asNullableMap(raw['propertyExt']),
    );
  }

  final ZaloThreadType threadType;
  final String msgId;
  final String? cliMsgId;
  final String threadId;
  final String senderUid;
  final String senderName;
  final String timestamp;
  final Object? content;
  final String msgType;
  final bool isSelf;
  final List<ZaloMention> mentions;
  final ZaloQuote? quote;
  final Map<String, dynamic>? propertyExt;

  bool get isPlainText => content is String;

  bool get isGroupMessage => threadType == ZaloThreadType.group;
}

class ZaloSendResult {
  const ZaloSendResult({required this.msgId});

  factory ZaloSendResult.fromJson(Map<String, dynamic> json) {
    return ZaloSendResult(msgId: json['msgId']?.toString() ?? '');
  }

  final String msgId;
}

class ZaloGroupChatHistory {
  const ZaloGroupChatHistory({
    required this.lastActionId,
    required this.more,
    required this.messages,
  });

  factory ZaloGroupChatHistory.fromJson(String uid, Map<String, dynamic> json) {
    return ZaloGroupChatHistory(
      lastActionId: json['lastActionId']?.toString() ?? '',
      more: _asInt(json['more']),
      messages: _asDynamicList(
        json['groupMsgs'],
      ).map((item) => ZaloMessage.fromGroup(uid, _asMap(item))).toList(),
    );
  }

  final String lastActionId;
  final int more;
  final List<ZaloMessage> messages;

  bool get hasMore => more > 0;
}

enum ZaloQrLoginEventType {
  generating,
  qrGenerated,
  scanned,
  confirmed,
  success,
}

class ZaloQrLoginEvent {
  const ZaloQrLoginEvent._({
    required this.type,
    this.qrImageBytes,
    this.qrCode,
    this.profile,
    this.result,
  });

  const ZaloQrLoginEvent.generating()
    : this._(type: ZaloQrLoginEventType.generating);

  const ZaloQrLoginEvent.qrGenerated({
    required Uint8List qrImageBytes,
    required String qrCode,
  }) : this._(
         type: ZaloQrLoginEventType.qrGenerated,
         qrImageBytes: qrImageBytes,
         qrCode: qrCode,
       );

  const ZaloQrLoginEvent.scanned({required ZaloProfile profile})
    : this._(type: ZaloQrLoginEventType.scanned, profile: profile);

  const ZaloQrLoginEvent.confirmed()
    : this._(type: ZaloQrLoginEventType.confirmed);

  const ZaloQrLoginEvent.success({required ZaloLoginResult result})
    : this._(type: ZaloQrLoginEventType.success, result: result);

  final ZaloQrLoginEventType type;
  final Uint8List? qrImageBytes;
  final String? qrCode;
  final ZaloProfile? profile;
  final ZaloLoginResult? result;
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

int _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }

  return int.tryParse(value?.toString() ?? '') ?? 0;
}

dynamic _pickValue(Map<String, dynamic> source, List<String> keys) {
  for (final key in keys) {
    if (source.containsKey(key)) {
      return source[key];
    }
  }

  return null;
}

String _stringValue(dynamic value, {String fallback = ''}) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? fallback : normalized;
}

String? _nullableString(dynamic value) {
  final normalized = value?.toString().trim() ?? '';
  return normalized.isEmpty ? null : normalized;
}

Map<String, dynamic>? _decodeJsonMap(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }

  try {
    final decoded = jsonDecode(value);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } catch (_) {
    return null;
  }
}

String _messageTypeFromClient(dynamic value) {
  switch (_asInt(value)) {
    case 31:
      return 'chat.voice';
    case 32:
      return 'chat.photo';
    case 36:
      return 'chat.sticker';
    case 37:
      return 'chat.doodle';
    case 38:
      return 'chat.recommended';
    case 43:
      return 'chat.location.new';
    case 44:
      return 'chat.video.msg';
    case 46:
      return 'share.file';
    case 49:
      return 'chat.gif';
    case 1:
    default:
      return 'webchat';
  }
}

bool _boolValue(dynamic value, {required bool fallback}) {
  if (value == null) {
    return fallback;
  }
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }

  final normalized = value.toString().trim().toLowerCase();
  if (normalized.isEmpty) {
    return fallback;
  }

  if (normalized == 'true' || normalized == '1') {
    return true;
  }
  if (normalized == 'false' || normalized == '0') {
    return false;
  }

  return fallback;
}

Map<String, dynamic> _deepFreezeMap(Map<String, dynamic> source) {
  return source.map((key, value) => MapEntry(key, _deepFreezeValue(value)));
}

dynamic _deepFreezeValue(dynamic value) {
  if (value is Map<String, dynamic>) {
    return Map<String, dynamic>.unmodifiable(_deepFreezeMap(value));
  }
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      _deepFreezeMap(Map<String, dynamic>.from(value)),
    );
  }
  if (value is List<String>) {
    return List<String>.unmodifiable(value);
  }
  if (value is List) {
    return List<dynamic>.unmodifiable(value.map(_deepFreezeValue));
  }

  return value;
}
