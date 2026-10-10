import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/flutter_zalo.dart';

/// In-memory socket that records what the client sends and lets the test
/// play the server.
class _ServerSocket implements ZaloWebSocketConnection {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final List<ZaloRealtimeFrame> sent = [];

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  void add(dynamic data) {
    final frame = parseZaloRealtimeFrame(data);
    if (frame != null) sent.add(frame);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!_controller.isClosed) await _controller.close();
  }

  void serverSend(int cmd, int subCmd, Map<String, dynamic> data) {
    _controller.add(
      buildZaloRealtimeFrame(version: 1, cmd: cmd, subCmd: subCmd, data: data),
    );
  }

  /// Unencrypted event body (encrypt 0), the shape the client decodes.
  void serverEvent(int cmd, int subCmd, Map<String, dynamic> data) {
    serverSend(cmd, subCmd, {
      'encrypt': 0,
      'data': jsonEncode({'data': data}),
    });
  }
}

ZaloDartClient _buildClient(_ServerSocket socket) {
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
  return ZaloDartClient.fromSnapshot(
    snapshot,
    socketConnector: (uri, {headers}) async => socket,
  );
}

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  test('listenerConnected waits for the cipher key, not just the open socket',
      () async {
    final socket = _ServerSocket();
    final client = _buildClient(socket);
    var connected = 0;
    client.listenerConnected.listen((_) => connected++);

    client.startListener().listen((_) {}, onError: (_) {});
    await _pump();
    expect(connected, 0);

    socket.serverSend(1, 1, {'key': base64Encode(List<int>.filled(16, 1))});
    await _pump();
    expect(connected, 1);
    await client.stopListener();
  });

  test('fetchOldGroupMessages sends cmd 511 after the given id and returns '
      'the group messages with the more flag', () async {
    final socket = _ServerSocket();
    final client = _buildClient(socket);
    client.startListener().listen((_) {}, onError: (_) {});
    await _pump();
    socket.serverSend(1, 1, {'key': base64Encode(List<int>.filled(16, 1))});
    await _pump();

    final future = client.fetchOldGroupMessages(lastMessageId: '100');
    await _pump();
    final request = socket.sent.lastWhere((f) => f.cmd == 511);
    expect(request.subCmd, 1);
    expect((jsonDecode(request.body) as Map)['lastId'], '100');

    socket.serverEvent(511, 1, {
      'more': 1,
      'groupMsgs': [
        {'msgId': '101', 'idTo': 'g1', 'uidFrom': 'u2', 'dName': 'B',
          'ts': '1700000000000', 'content': 'csct', 'msgType': 'webchat'},
        {'msgId': '102', 'idTo': 'g2', 'uidFrom': '0', 'dName': 'Me',
          'ts': '1700000001000', 'content': 'ok', 'msgType': 'webchat'},
      ],
    });
    final page = await future;

    expect(page.hasMore, isTrue);
    expect(page.messages.map((m) => m.msgId), ['101', '102']);
    expect(page.messages.first.threadId, 'g1');
    expect(page.messages.last.isSelf, isTrue);
    await client.stopListener();
  });

  test('fetchOldGroupMessages fails fast before the socket is ready', () {
    final client = _buildClient(_ServerSocket());
    expect(() => client.fetchOldGroupMessages(), throwsStateError);
  });
}
