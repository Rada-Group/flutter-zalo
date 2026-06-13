import 'dart:developer' as developer;
import 'package:flutter/foundation.dart';

void zaloLog(
  String message, {
  String name = 'flutter_zalo',
  Map<String, Object?> data = const <String, Object?>{},
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!kDebugMode) return;
  final suffix = data.isEmpty
      ? ''
      : ' ${data.entries.map((e) => '${e.key}=${_fmt(e.value)}').join(' ')}';
  developer.log(
    '$message$suffix',
    name: name,
    error: error,
    stackTrace: stackTrace,
  );
  if (kDebugMode) debugPrint('[$name] $message$suffix${error != null ? ' error=$error' : ''}');
}

String maskValue(String? value, {int head = 4, int tail = 4}) {
  if (value == null || value.isEmpty) return '';
  if (value.length <= head + tail) return '*' * value.length;
  return '${value.substring(0, head)}...${value.substring(value.length - tail)}';
}

String truncateValue(String? value, {int maxLength = 80}) {
  if (value == null || value.isEmpty || value.length <= maxLength) return value ?? '';
  if (maxLength <= 3) return value.substring(0, maxLength);
  return '${value.substring(0, maxLength - 3)}...';
}

String _fmt(Object? value) {
  if (value == null) return 'null';
  if (value is Iterable) return '[${value.map(_fmt).join(',')}]';
  if (value is Map) return '{${value.entries.map((e) => '${e.key}:${_fmt(e.value)}').join(',')}}';
  return value.toString();
}
