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
