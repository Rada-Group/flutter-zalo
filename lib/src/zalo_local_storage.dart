/// Minimal key-value storage interface used by flutter_zalo.
/// Implement this in your app and inject it into [ZaloGroupCatalogCache]
/// and [ZaloGroupNotificationRepository].
abstract class ZaloLocalStorage {
  Set<String> getKeys();
  bool? getBool(String key);
  String? getString(String key);
  Future<bool> setBool(String key, bool value);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);
}
