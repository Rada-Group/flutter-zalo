import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/src/zalo_groups_repository.dart';
import 'package:flutter_zalo/src/zalo_models.dart';

class _CapturingAdapter implements HttpClientAdapter {
  RequestOptions? captured;
  String? capturedBody;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured = options;
    capturedBody = options.data is String
        ? options.data as String
        : jsonEncode(options.data);
    return ResponseBody.fromString(
      jsonEncode({'data': {'groups': [], 'created': 0, 'updated': 0, 'synced': 0}}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

void main() {
  test('syncGroups includes zalo_account_name when provided', () async {
    final dio = Dio(BaseOptions(baseUrl: 'https://example.test'));
    final adapter = _CapturingAdapter();
    dio.httpClientAdapter = adapter;
    final repo = ZaloGroupsRepository(dio);

    await repo.syncGroups(
      <ZaloGroup>[
        ZaloGroup(
          groupId: 'g1',
          name: 'Nhóm 1',
          description: '',
          memberCount: 0,
          maxMemberCount: 0,
          avatarUrl: null,
          version: '',
          isCommunity: false,
        ),
      ],
      zaloAccountId: 'uid-1',
      zaloAccountName: 'Tài xế A',
    );

    final body = jsonDecode(adapter.capturedBody!) as Map<String, dynamic>;
    expect(body['zalo_account_id'], 'uid-1');
    expect(body['zalo_account_name'], 'Tài xế A');
  });
}
