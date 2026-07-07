// flutter-zalo/test/zalo_info_batch_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

void main() {
  group('chunkZaloIds', () {
    test('trims, dedups (order-preserving) and splits into batches', () {
      final result = chunkZaloIds([' a ', 'b', 'a', '', 'c', 'd'], 2);
      expect(result, [
        ['a', 'b'],
        ['c', 'd'],
      ]);
    });

    test('returns empty list for empty input', () {
      expect(chunkZaloIds(const <String>[], 50), isEmpty);
    });

    test('throws when size <= 0', () {
      expect(() => chunkZaloIds(['a'], 0), throwsArgumentError);
    });
  });
}
