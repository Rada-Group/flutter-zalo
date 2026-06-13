import 'package:dio/dio.dart';

import 'zalo_models.dart';

class ZaloGroupsRepository {
  ZaloGroupsRepository(this._dio);

  static const _syncPath = '/zalo-groups/sync';
  static const _myGroupsPath = '/zalo-groups/my-groups';

  final Dio _dio;

  Future<ZaloGroupCatalogSyncResult> syncGroups(
    Iterable<ZaloGroup> groups,
  ) async {
    final response = await _dio.post<dynamic>(
      _syncPath,
      data: {
        'groups': groups
            .map(
              (group) => <String, dynamic>{
                'zalo_group_id': group.groupId,
                'name': group.name,
                if (group.memberCount > 0) 'member_count': group.memberCount,
                if (group.avatarUrl != null &&
                    group.avatarUrl!.trim().isNotEmpty)
                  'avatar_url': group.avatarUrl!.trim(),
                if (group.creatorId != null &&
                    group.creatorId!.trim().isNotEmpty)
                  'creator_id': group.creatorId!.trim(),
              },
            )
            .toList(growable: false),
      },
    );

    return ZaloGroupCatalogSyncResult.fromJson(_asMap(response.data));
  }

  Future<List<ZaloGroupCatalogEntry>> getMyGroups() async {
    final response = await _dio.get<dynamic>(_myGroupsPath);
    final items = _asGroupList(response.data);

    return items
        .map((item) => ZaloGroupCatalogEntry.fromJson(_asMap(item)))
        .toList(growable: false);
  }

  Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map) {
      return Map<String, dynamic>.from(data);
    }

    throw const FormatException('API response must be a JSON object.');
  }

  List<dynamic> _asList(dynamic data) {
    if (data is List<dynamic>) {
      return data;
    }
    if (data is List) {
      return List<dynamic>.from(data);
    }

    throw const FormatException('API response must be a JSON array.');
  }

  List<dynamic> _asGroupList(dynamic data) {
    if (data is List || data is List<dynamic>) {
      return _asList(data);
    }

    final payload = _asMap(data);
    final items = payload['groups'] ?? payload['items'];
    if (items is List || items is List<dynamic>) {
      return _asList(items);
    }

    throw const FormatException('API response must contain a group list.');
  }
}
