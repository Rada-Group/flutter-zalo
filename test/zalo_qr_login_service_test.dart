import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/src/zalo_models.dart';
import 'package:flutter_zalo/src/zalo_qr_login_service.dart';

/// Trả về response cho các bước bootstrap chung (login page, logininfo,
/// verify-client, generate) — giống hệt nhau ở mọi test trong file này.
/// Trả `null` nếu [path] không phải một trong các bước bootstrap, để caller
/// tự xử lý các endpoint còn lại (waiting-scan/waiting-confirm).
ResponseBody? _bootstrapResponse(String path) {
  switch (path) {
    case '/account':
      return _html(
        '<script src="https://stc-zlogin.zdn.vn/main-1.0.0.js"></script>',
      );
    case '/account/logininfo':
    case '/account/verify-client':
    case '/account/checksession':
      return _json(const {'error_code': 0});
    case '/account/authen/qr/generate':
      return _json({
        'data': {
          'code': 'qr-code-1',
          'image': 'data:image/png;base64,${base64Encode(<int>[1, 2, 3])}',
        },
      });
    case '/jr/userinfo':
      return _json({
        'error_code': 0,
        'data': {
          'logged': true,
          'session_chat_valid': true,
          'info': {
            'name': 'Test User',
            'avatar': '',
          },
        },
      });
    default:
      return null;
  }
}

ResponseBody _json(Map<String, dynamic> body) => ResponseBody.fromString(
  jsonEncode(body),
  200,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _html(String body) => ResponseBody.fromString(
  body,
  200,
  headers: {
    Headers.contentTypeHeader: ['text/html'],
  },
);

/// Scripts the QR login HTTP calls, injecting one connection-abort error on the first waiting-scan poll.
class _ScriptedAdapter implements HttpClientAdapter {
  int waitingScanCalls = 0;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final bootstrap = _bootstrapResponse(path);
    if (bootstrap != null) {
      return bootstrap;
    }

    if (path == '/account/authen/qr/waiting-scan') {
      waitingScanCalls += 1;
      if (waitingScanCalls == 1) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.unknown,
          error: const HttpException(
            'Software caused connection abort, uri = '
            'https://id.zalo.me/account/authen/qr/waiting-scan',
          ),
        );
      }
      return _json({
        'error_code': 0,
        'data': {'display_name': 'Tài xế A', 'avatar': ''},
      });
    }

    throw StateError('Unexpected request: $path');
  }
}

/// Trả về thành công ngay lần poll đầu tiên cho cả waiting-scan lẫn
/// waiting-confirm — dùng để chứng minh một kết quả thành công thật từ
/// server luôn được ưu tiên hơn đồng hồ hết hạn cục bộ.
class _ImmediateSuccessAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final bootstrap = _bootstrapResponse(path);
    if (bootstrap != null) {
      return bootstrap;
    }
    if (path == '/account/authen/qr/waiting-scan') {
      return _json({
        'error_code': 0,
        'data': {'display_name': 'Tài xế A', 'avatar': ''},
      });
    }
    if (path == '/account/authen/qr/waiting-confirm') {
      return _json(const {'error_code': 0});
    }
    throw StateError('Unexpected request: $path');
  }
}

/// Luôn trả `error_code: 8` ("còn đang chờ") cho waiting-scan/waiting-confirm
/// — dùng để chứng minh service vẫn báo hết hạn đúng khi thật sự hết thời
/// gian và server không bao giờ xác nhận.
class _AlwaysWaitingAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final bootstrap = _bootstrapResponse(path);
    if (bootstrap != null) {
      return bootstrap;
    }
    if (path == '/account/authen/qr/waiting-scan' ||
        path == '/account/authen/qr/waiting-confirm') {
      return _json(const {'error_code': 8});
    }
    throw StateError('Unexpected request: $path');
  }
}

void main() {
  test(
    'startLogin retries the waiting-scan poll after a transient connection-abort error '
    'instead of failing the whole QR login',
    () async {
      final dio = Dio(
        BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true),
      );
      dio.httpClientAdapter = _ScriptedAdapter();
      final service = ZaloQrLoginService(client: dio);

      final scannedProfile = Completer<ZaloProfile>();
      final subscription = service.startLogin().listen(
        (event) {
          if (event.type == ZaloQrLoginEventType.scanned) {
            scannedProfile.complete(event.profile);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!scannedProfile.isCompleted) {
            scannedProfile.completeError(error, stackTrace);
          }
        },
      );

      final profile = await scannedProfile.future.timeout(
        const Duration(seconds: 5),
      );
      await subscription.cancel();

      expect(profile.displayName, 'Tài xế A');
    },
  );

  test(
    'succeeds even if the local QR timer already elapsed, as long as the '
    'server confirms on the very next poll',
    () async {
      final dio = Dio(
        BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true),
      );
      dio.httpClientAdapter = _ImmediateSuccessAdapter();
      final service = ZaloQrLoginService(
        client: dio,
        qrExpiresAfter: Duration.zero,
      );

      final events = <ZaloQrLoginEvent>[];
      await service.startLogin().forEach(events.add);

      expect(
        events.map((event) => event.type),
        contains(ZaloQrLoginEventType.success),
      );
    },
  );

  test(
    'throws ZaloQrExpiredException once the timer is up and the server '
    'keeps saying "still waiting"',
    () async {
      final dio = Dio(
        BaseOptions(responseType: ResponseType.plain, validateStatus: (_) => true),
      );
      dio.httpClientAdapter = _AlwaysWaitingAdapter();
      final service = ZaloQrLoginService(
        client: dio,
        qrExpiresAfter: Duration.zero,
      );

      await expectLater(
        service.startLogin().drain<void>(),
        throwsA(isA<ZaloQrExpiredException>()),
      );
    },
  );
}
