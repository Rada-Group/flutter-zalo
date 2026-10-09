import 'zalo_local_storage.dart';

class ZaloGroupNotificationRepository {
  const ZaloGroupNotificationRepository(this._storageBuilder);

  static const _keyPrefix = 'zalo.group_notifications.v1';

  final Future<ZaloLocalStorage> Function() _storageBuilder;

  Future<bool?> isEnabled(String accountId, String groupId) async {
    final normalizedAccountId = accountId.trim();
    final normalizedGroupId = groupId.trim();
    if (normalizedAccountId.isEmpty || normalizedGroupId.isEmpty) {
      return null;
    }

    final storage = await _storageBuilder();
    return storage.getBool(_key(normalizedAccountId, normalizedGroupId));
  }

  Future<void> setEnabled({
    required String accountId,
    required String groupId,
    required bool enabled,
  }) async {
    final normalizedAccountId = accountId.trim();
    final normalizedGroupId = groupId.trim();
    if (normalizedAccountId.isEmpty || normalizedGroupId.isEmpty) {
      return;
    }

    final storage = await _storageBuilder();
    await storage.setBool(
      _key(normalizedAccountId, normalizedGroupId),
      enabled,
    );
  }

  /// Mọi thread id (nhóm **và** chat 1-1) mà override đang bật `true` cho
  /// [accountId].
  ///
  /// Đọc thẳng từ store thay vì đối chiếu với một danh sách nhóm/thread có sẵn:
  /// đây mới là nguồn sự thật của tập opt-in, nên caller không phụ thuộc vào
  /// việc group catalog hay thread store đã nạp xong hay chưa.
  Future<Set<String>> enabledIds(String accountId) =>
      _idsWithValue(accountId, true);

  /// Mọi thread id mà override đang là `false` cho [accountId]: người dùng đã
  /// chủ động tắt. App có mặc định BẬT dùng tập này làm blacklist.
  Future<Set<String>> disabledIds(String accountId) =>
      _idsWithValue(accountId, false);

  Future<Set<String>> _idsWithValue(String accountId, bool value) async {
    final normalizedAccountId = accountId.trim();
    if (normalizedAccountId.isEmpty) {
      return const <String>{};
    }

    final storage = await _storageBuilder();
    final prefix = '$_keyPrefix.$normalizedAccountId.';
    final ids = <String>{};
    for (final key in storage.getKeys()) {
      if (!key.startsWith(prefix)) {
        continue;
      }
      if (storage.getBool(key) != value) {
        continue;
      }

      final threadId = key.substring(prefix.length);
      if (threadId.isNotEmpty) {
        ids.add(threadId);
      }
    }

    return ids;
  }

  Future<void> clearAll() async {
    final storage = await _storageBuilder();
    final keys = storage
        .getKeys()
        .where((key) => key.startsWith('$_keyPrefix.'))
        .toList(growable: false);
    await Future.wait(keys.map(storage.remove));
  }

  String _key(String accountId, String groupId) {
    return '$_keyPrefix.$accountId.$groupId';
  }
}

bool effectiveGroupNotificationEnabled({
  required bool? localOverride,
  required bool serverActive,
}) {
  return localOverride ?? serverActive;
}
