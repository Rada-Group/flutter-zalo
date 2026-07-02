import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

/// A controllable in-memory WebSocket so we can reproduce the exact failure
/// modes that make the real Zalo socket stop delivering messages:
/// a silent half-open socket, a server-initiated close, and a hung connect.
class _FakeWsConnection implements ZaloWebSocketConnection {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  int? _closeCode;
  String? _closeReason;
  bool closed = false;

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  void add(dynamic data) {}

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) return;
    closed = true;
    _closeCode ??= code;
    _closeReason ??= reason;
    if (!_controller.isClosed) {
      await _controller.close();
    }
  }

  /// Simulate the *server* closing the socket with [code] (not a manual stop).
  void serverClose(int code, [String reason = '']) {
    _closeCode = code;
    _closeReason = reason;
    closed = true;
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}

ZaloDartClient _buildClient(ZaloSocketConnector connector) {
  final snapshot = ZaloConnectionSnapshot(
    credentials: const ZaloCredentials(
      cookie: 'cookie',
      imei: 'imei',
      userAgent: 'ua',
    ),
    profile: const ZaloProfile(displayName: 'Tester', avatarUrl: ''),
    session: ZaloSessionInfo(
      userId: 'uid-1',
      secretKey: 'secret',
      serviceMap: const <String, List<String>>{},
      wsUrls: const <String>['wss://ws.example.test/'],
      settings: const <String, dynamic>{},
      extraVersions: const <String, dynamic>{},
    ),
  );
  return ZaloDartClient.fromSnapshot(snapshot, socketConnector: connector);
}

void main() {
  test(
    'reconnects when the socket goes silent without ever closing (half-open)',
    () {
      fakeAsync((async) {
        var connectCount = 0;
        final sockets = <_FakeWsConnection>[];
        final client = _buildClient((uri, {headers}) async {
          connectCount++;
          final socket = _FakeWsConnection();
          sockets.add(socket);
          return socket;
        });

        client.startListener();
        async.flushMicrotasks();
        expect(connectCount, 1, reason: 'listener should connect once on start');

        // The socket stays open but never delivers a frame and never fires
        // onDone — a classic mobile half-open connection. Give the liveness
        // watchdog plenty of virtual time to notice and recover.
        async.elapse(const Duration(minutes: 10));

        expect(
          connectCount,
          greaterThan(1),
          reason: 'watchdog must force-close the dead socket and reconnect',
        );
        expect(
          sockets.first.closed,
          isTrue,
          reason: 'the dead socket should have been force-closed',
        );

        client.stopListener();
        async.flushMicrotasks();
      });
    },
  );

  test('reconnects after the server closes the socket with code 1000', () {
    fakeAsync((async) {
      var connectCount = 0;
      _FakeWsConnection? current;
      final client = _buildClient((uri, {headers}) async {
        connectCount++;
        current = _FakeWsConnection();
        return current!;
      });

      client.startListener();
      async.flushMicrotasks();
      expect(connectCount, 1);

      // A server-initiated normal close (NOT a manual stopListener on our side).
      current!.serverClose(1000);
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 2));

      expect(
        connectCount,
        greaterThan(1),
        reason: 'a server-side close must not permanently kill the listener',
      );

      client.stopListener();
      async.flushMicrotasks();
    });
  });

  test('retries when a connect attempt hangs past the timeout', () {
    fakeAsync((async) {
      var connectCount = 0;
      final client = _buildClient((uri, {headers}) {
        connectCount++;
        if (connectCount == 1) {
          // Never completes — simulates a TCP connect that hangs forever.
          return Completer<ZaloWebSocketConnection>().future;
        }
        return Future<ZaloWebSocketConnection>.value(_FakeWsConnection());
      });

      client.startListener();
      async.flushMicrotasks();
      expect(connectCount, 1);

      async.elapse(const Duration(minutes: 2));

      expect(
        connectCount,
        greaterThan(1),
        reason: 'a hung connect must time out and trigger a retry',
      );

      client.stopListener();
      async.flushMicrotasks();
    });
  });

  test('does not reconnect after a manual stopListener()', () {
    fakeAsync((async) {
      var connectCount = 0;
      final client = _buildClient((uri, {headers}) async {
        connectCount++;
        return _FakeWsConnection();
      });

      client.startListener();
      async.flushMicrotasks();
      expect(connectCount, 1);

      client.stopListener();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 10));

      expect(
        connectCount,
        1,
        reason: 'a manual stop must never trigger an auto-reconnect',
      );
    });
  });
}
