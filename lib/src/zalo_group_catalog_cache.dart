import 'dart:convert';

import 'zalo_local_storage.dart';
import 'zalo_models.dart';

class ZaloGroupCatalogCache {
  ZaloGroupCatalogCache(this._storageLoader);

  static const _storageKeyPrefix = 'zalo.group_catalog.v1';

  final Future<ZaloLocalStorage> Function() _storageLoader;

  Future<ZaloGroupCatalogCacheRecord?> read(String userId) async {
    final storageKey = _storageKey(userId);
    if (storageKey == null) {
      return null;
    }

    try {
      final storage = await _storageLoader();
      final raw = storage.getString(storageKey);
      if (raw == null || raw.trim().isEmpty) {
        return null;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return null;
      }

      final payload = Map<String, dynamic>.from(decoded);
      final groupsPayload = payload['groups'];
      if (groupsPayload is! List) {
        return null;
      }

      final groups = groupsPayload
          .whereType<Map>()
          .map(
            (item) =>
                ZaloGroupCatalogEntry.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);

      return ZaloGroupCatalogCacheRecord(
        groups: groups,
        lastSyncedAt: _dateTimeOrNull(
          payload['last_synced_at'] ?? payload['lastSyncedAt'],
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> write(
    String userId, {
    required List<ZaloGroupCatalogEntry> groups,
    DateTime? lastSyncedAt,
  }) async {
    final storageKey = _storageKey(userId);
    if (storageKey == null) {
      return;
    }

    try {
      final storage = await _storageLoader();
      await storage.setString(
        storageKey,
        jsonEncode(<String, dynamic>{
          'groups': groups
              .map((group) => group.toJson())
              .toList(growable: false),
          'last_synced_at': lastSyncedAt?.toUtc().toIso8601String(),
        }),
      );
    } catch (_) {}
  }

  Future<void> clear(String userId) async {
    final storageKey = _storageKey(userId);
    if (storageKey == null) {
      return;
    }

    try {
      final storage = await _storageLoader();
      await storage.remove(storageKey);
    } catch (_) {}
  }

  Future<void> clearAll() async {
    try {
      final storage = await _storageLoader();
      final keys = storage
          .getKeys()
          .where((key) => key.startsWith('$_storageKeyPrefix.'))
          .toList(growable: false);
      await Future.wait(keys.map(storage.remove));
    } catch (_) {}
  }

  String? _storageKey(String userId) {
    final normalizedUserId = userId.trim();
    if (normalizedUserId.isEmpty) {
      return null;
    }

    return '$_storageKeyPrefix.$normalizedUserId';
  }

  DateTime? _dateTimeOrNull(Object? value) {
    if (value == null) {
      return null;
    }

    final normalizedValue = value.toString().trim();
    if (normalizedValue.isEmpty) {
      return null;
    }

    return DateTime.tryParse(normalizedValue)?.toUtc();
  }
}

class ZaloGroupCatalogCacheRecord {
  ZaloGroupCatalogCacheRecord({
    required List<ZaloGroupCatalogEntry> groups,
    required this.lastSyncedAt,
  }) : groups = List<ZaloGroupCatalogEntry>.unmodifiable(groups);

  final List<ZaloGroupCatalogEntry> groups;
  final DateTime? lastSyncedAt;
}
