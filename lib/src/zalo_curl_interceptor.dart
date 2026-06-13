import 'dart:convert';
import 'dart:developer' as developer;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'zalo_logger.dart' show maskValue;

typedef ApiLogBodyDecoder = Object? Function(Object? data);

class ZaloCurlLoggingInterceptor extends Interceptor {
  static const responseDecoderExtraKey = 'pam_api_log_response_decoder';
  static const _logName = 'PAM.API';
  static const _startedAtExtraKey = 'pam_api_log_started_at';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startedAtExtraKey] = DateTime.now().millisecondsSinceEpoch;
    _log('REQUEST ${options.method} ${options.uri}');
    _log(_buildCurlCommand(options));
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final elapsedMs = _elapsedMs(response.requestOptions);
    _log(
      'RESPONSE ${response.requestOptions.method} ${response.statusCode} '
      '${response.requestOptions.uri} ${elapsedMs}ms',
    );
    _log('RESPONSE HEADERS ${_formatHeaders(response.headers.map)}');
    _logBody('RESPONSE BODY', response.data);
    _logDecodedBody(
      'RESPONSE DECODED BODY',
      response.requestOptions,
      response.data,
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final response = err.response;
    if (response == null) {
      _log(
        'ERROR ${err.requestOptions.method} ${err.requestOptions.uri} '
        'failed: ${err.type.name} ${err.message ?? ''}',
      );
      handler.next(err);
      return;
    }

    _log(
      'ERROR ${err.requestOptions.method} ${response.statusCode} '
      '${err.requestOptions.uri} ${_elapsedMs(err.requestOptions)}ms',
    );
    _log('ERROR HEADERS ${_formatHeaders(response.headers.map)}');
    _logBody('ERROR BODY', response.data);
    _logDecodedBody(
      'ERROR DECODED BODY',
      response.requestOptions,
      response.data,
    );
    handler.next(err);
  }

  String _buildCurlCommand(RequestOptions options) {
    final buffer = StringBuffer('curl');
    final method = options.method.toUpperCase();
    if (method != 'GET') {
      buffer.write(' -X $method');
    }

    for (final entry in options.headers.entries) {
      final value = _sanitizeHeader(entry.key, entry.value);
      buffer.write(' -H ${_shellQuote('${entry.key}: $value')}');
    }

    final data = options.data;
    if (data != null) {
      buffer.write(' -d ${_shellQuote(_formatBody(data))}');
    }

    buffer.write(' ${_shellQuote(options.uri.toString())}');
    return buffer.toString();
  }

  String _sanitizeHeader(String key, Object? value) {
    final normalizedKey = key.toLowerCase();
    if (normalizedKey == 'authorization') {
      final rawValue = value?.toString() ?? '';
      if (rawValue.startsWith('Bearer ')) {
        return 'Bearer ${maskValue(rawValue.substring(7), head: 8, tail: 6)}';
      }

      return maskValue(rawValue, head: 8, tail: 6);
    }

    if (normalizedKey.contains('cookie') || normalizedKey.contains('token')) {
      return '<redacted>';
    }

    return value?.toString() ?? '';
  }

  String _formatBody(Object? data) {
    if (data == null) {
      return 'null';
    }

    String value;
    if (data is String) {
      value = data;
    } else if (data is FormData) {
      final fields = data.fields.map((entry) => entry.key).join(',');
      final files = data.files.map((entry) => entry.key).join(',');
      value = 'FormData(fields=[$fields], files=[$files])';
    } else {
      try {
        value = jsonEncode(data);
      } catch (_) {
        value = data.toString();
      }
    }

    return value;
  }

  String _formatHeaders(Map<String, List<String>> headers) {
    if (headers.isEmpty) {
      return '{}';
    }

    final sanitized = <String, String>{};
    for (final entry in headers.entries) {
      final value = entry.value.join(',');
      sanitized[entry.key] = _sanitizeHeader(entry.key, value);
    }

    return jsonEncode(sanitized);
  }

  void _logBody(String label, Object? data) {
    final body = _formatBody(data);
    _log('$label type=${data.runtimeType} length=${body.length} $body');
  }

  void _logDecodedBody(String label, RequestOptions options, Object? data) {
    final decoder = options.extra[responseDecoderExtraKey];
    if (decoder is! ApiLogBodyDecoder) {
      return;
    }

    try {
      final decoded = decoder(data);
      if (decoded == null) {
        return;
      }

      _logBody(label, decoded);
    } catch (error) {
      _log('$label decode_failed=$error');
    }
  }

  int _elapsedMs(RequestOptions options) {
    final startedAt = options.extra[_startedAtExtraKey];
    if (startedAt is! int) {
      return 0;
    }

    return DateTime.now().millisecondsSinceEpoch - startedAt;
  }

  String _shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  void _log(String message) {
    if (!kDebugMode) {
      return;
    }

    developer.log('[$_logName] $message', name: _logName);
  }
}
