import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

void main() {
  test('public API exports core transport types', () {
    expect(ZaloDartClient, isNotNull);
    expect(ZaloCredentials, isNotNull);
    expect(ZaloQrLoginService, isNotNull);
    expect(ZaloLocalStorage, isNotNull);
  });
}
