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

  group('parseZaloGroupInfoResponse', () {
    test('parses gridInfoMap + removed + unchanged', () {
      final batch = parseZaloGroupInfoResponse({
        'gridInfoMap': {
          'g1': {'groupId': 'g1', 'name': 'Nhóm A', 'avt': 'http://a', 'totalMember': 5, 'version': '12'},
        },
        'removedsGroup': ['g2'],
        'unchangedsGroup': ['g3'],
      });
      expect(batch.infos['g1']!.name, 'Nhóm A');
      expect(batch.infos['g1']!.avatarUrl, 'http://a');
      expect(batch.infos['g1']!.version, '12');
      expect(batch.removedGroupIds, ['g2']);
      expect(batch.unchangedGroupIds, ['g3']);
    });

    test('tolerates missing buckets', () {
      final batch = parseZaloGroupInfoResponse(const {});
      expect(batch.infos, isEmpty);
      expect(batch.removedGroupIds, isEmpty);
      expect(batch.unchangedGroupIds, isEmpty);
    });
  });
}
