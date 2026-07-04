import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

/// A WS we can server-close with an arbitrary code, mirroring the reconnect test.
class _FakeWs implements ZaloWebSocketConnection {
  final _c = StreamController<dynamic>();
  int? _code;
  @override
  Stream<dynamic> get stream => _c.stream;
  @override
  int? get closeCode => _code;
  @override
  String? get closeReason => '';
  @override
  void add(dynamic data) {}
  @override
  Future<void> close([int? code, String? reason]) async {
    _code ??= code;
    if (!_c.isClosed) await _c.close();
  }
  void serverClose(int code) {
    _code = code;
    if (!_c.isClosed) _c.close();
  }
}

/// Adapter that returns a fixed HTTP status for every request.
class _StatusAdapter implements HttpClientAdapter {
  _StatusAdapter(this.status);
  final int status;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    return ResponseBody.fromString('{}', status,
        headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }
}

ZaloConnectionSnapshot _snapshot() => ZaloConnectionSnapshot(
      credentials: const ZaloCredentials(cookie: 'c', imei: 'i', userAgent: 'ua'),
      profile: const ZaloProfile(displayName: 'T', avatarUrl: ''),
      session: ZaloSessionInfo(
        userId: 'uid-1',
        secretKey: 'secret',
        serviceMap: const {'chat': ['https://chat.example.test']},
        wsUrls: const ['wss://ws.example.test/'],
        settings: const {},
        extraVersions: const {},
      ),
    );

void main() {
  test('HTTP 401 routes onSessionInvalidated with unauthorized', () async {
    ZaloSessionEndReason? captured;
    // Mirror the production client (_buildHttpClient) which never rejects on
    // status so the 401 branch inside _request is reached instead of Dio
    // throwing first.
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = _StatusAdapter(401);
    final client = ZaloDartClient.fromSnapshot(
      _snapshot(),
      client: dio,
      onSessionInvalidated: (reason) async => captured = reason,
    );

    // initSession() issues a plain GET (getLoginInfo) that flows through
    // _request, so the injected 401 hits the unauthorized branch. keepAlive()
    // can't be used here: it encrypts its payload with the (fake) session key
    // and throws before any HTTP request is made.
    await expectLater(client.initSession(), throwsA(isA<ZaloLoginException>()));
    // callback is fire-and-forget inside _request and awaits stopListener before
    // firing, so give the chain time to settle (mirrors the WS test below).
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(captured, ZaloSessionEndReason.unauthorized);
  });

  test('WS server-close 3003 routes onSessionInvalidated with takenOver', () async {
    ZaloSessionEndReason? captured;
    final ws = _FakeWs();
    final client = ZaloDartClient.fromSnapshot(
      _snapshot(),
      socketConnector: (uri, {headers}) async => ws,
      onSessionInvalidated: (reason) async => captured = reason,
    );
    client.startListener();
    await Future<void>.delayed(Duration.zero);
    ws.serverClose(3003);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(captured, ZaloSessionEndReason.takenOver);
    await client.stopListener();
  });
}
