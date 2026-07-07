import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

/// Adapter that returns a fixed HTTP status for every request.
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);
  final int status;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    return ResponseBody.fromString(
      '{}',
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }
}

// Valid base64 for a 16-byte AES key so encodeZaloPayload() does not throw
// before the request reaches the HTTP layer.
const _validSecretKey = 'AAAAAAAAAAAAAAAAAAAAAA==';

ZaloConnectionSnapshot _snapshot() => ZaloConnectionSnapshot(
      credentials: const ZaloCredentials(cookie: 'c', imei: 'i', userAgent: 'ua'),
      profile: const ZaloProfile(displayName: 'T', avatarUrl: ''),
      session: ZaloSessionInfo(
        userId: 'uid-1',
        secretKey: _validSecretKey,
        serviceMap: const {
          'group': ['https://group.example.test'],
          'profile': ['https://profile.example.test'],
        },
        wsUrls: const ['wss://ws.example.test/'],
        settings: const {},
        extraVersions: const {},
      ),
    );

void main() {
  test(
    'HTTP 401 on fetchGroupInfoBatch does NOT invalidate the session',
    () async {
      ZaloSessionEndReason? captured;
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _StatusAdapter(401);
      final client = ZaloDartClient.fromSnapshot(
        _snapshot(),
        client: dio,
        onSessionInvalidated: (reason) async => captured = reason,
      );

      await expectLater(
        client.fetchGroupInfoBatch(['123']),
        throwsA(isA<Exception>()),
      );
      // Give the fire-and-forget invalidation chain time to settle if it were
      // (incorrectly) triggered.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(captured, isNull);
    },
  );

  test(
    'HTTP 401 on fetchUserInfoBatch does NOT invalidate the session',
    () async {
      ZaloSessionEndReason? captured;
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = _StatusAdapter(401);
      final client = ZaloDartClient.fromSnapshot(
        _snapshot(),
        client: dio,
        onSessionInvalidated: (reason) async => captured = reason,
      );

      await expectLater(
        client.fetchUserInfoBatch(['123']),
        throwsA(isA<Exception>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(captured, isNull);
    },
  );
}
