import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

class _MemoryStorage implements ZaloLocalStorage {
  final Map<String, Object?> _values = <String, Object?>{};

  @override
  Set<String> getKeys() => _values.keys.toSet();

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<bool> setBool(String key, bool value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> setString(String key, String value) async {
    _values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _values.remove(key);
    return true;
  }
}

void main() {
  group('ZaloGroupNotificationRepository.enabledIds', () {
    late _MemoryStorage storage;
    late ZaloGroupNotificationRepository repository;

    setUp(() {
      storage = _MemoryStorage();
      repository = ZaloGroupNotificationRepository(() async => storage);
    });

    test('returns only the ids explicitly turned on', () async {
      await repository.setEnabled(
        accountId: 'acc-1',
        groupId: 'group-on',
        enabled: true,
      );
      await repository.setEnabled(
        accountId: 'acc-1',
        groupId: 'group-off',
        enabled: false,
      );

      expect(await repository.enabledIds('acc-1'), {'group-on'});
    });

    test('covers 1-1 thread ids, not just groups', () async {
      await repository.setEnabled(
        accountId: 'acc-1',
        groupId: 'user-1',
        enabled: true,
      );

      expect(await repository.enabledIds('acc-1'), {'user-1'});
    });

    test('never leaks another account entries', () async {
      await repository.setEnabled(
        accountId: 'acc-2',
        groupId: 'group-on',
        enabled: true,
      );

      expect(await repository.enabledIds('acc-1'), isEmpty);
      expect(await repository.enabledIds('acc-2'), {'group-on'});
    });

    test('an account with nothing turned on stays empty', () async {
      expect(await repository.enabledIds('acc-1'), isEmpty);
      expect(await repository.enabledIds('   '), isEmpty);
    });
  });

  group('ZaloGroupNotificationRepository.disabledIds', () {
    late _MemoryStorage storage;
    late ZaloGroupNotificationRepository repository;

    setUp(() {
      storage = _MemoryStorage();
      repository = ZaloGroupNotificationRepository(() async => storage);
    });

    test('returns only the ids explicitly turned off', () async {
      await repository.setEnabled(
        accountId: 'acc-1',
        groupId: 'group-on',
        enabled: true,
      );
      await repository.setEnabled(
        accountId: 'acc-1',
        groupId: 'group-off',
        enabled: false,
      );

      expect(await repository.disabledIds('acc-1'), {'group-off'});
      expect(await repository.enabledIds('acc-1'), {'group-on'});
    });

    test('never leaks another account entries', () async {
      await repository.setEnabled(
        accountId: 'acc-2',
        groupId: 'group-off',
        enabled: false,
      );

      expect(await repository.disabledIds('acc-1'), isEmpty);
      expect(await repository.disabledIds('acc-2'), {'group-off'});
    });

    test('blank account yields an empty set', () async {
      expect(await repository.disabledIds('   '), isEmpty);
    });
  });
}
