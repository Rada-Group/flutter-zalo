import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zalo/src/zalo_models.dart';
import 'package:flutter_zalo/src/zalo_qr_login_service.dart';

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

    if (path == '/account') {
      return _html(
        '<script src="https://stc-zlogin.zdn.vn/main-1.0.0.js"></script>',
      );
    }
    if (path == '/account/logininfo' || path == '/account/verify-client') {
      return _json(const {'error_code': 0});
    }
    if (path == '/account/authen/qr/generate') {
      return _json({
        'data': {
          'code': 'qr-code-1',
          'image': 'data:image/png;base64,${base64Encode(<int>[1, 2, 3])}',
        },
      });
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
}
