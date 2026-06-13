import 'dart:convert';

import 'zalo_models.dart';

const _previewableMediaTypes = <String>{'chat.photo', 'chat.video.msg'};
const _captionKeys = <String>[
  'text',
  'description',
  'desc',
  'caption',
  'title',
  'msg',
];
const _mediaKeys = <String>[
  'previewThumb',
  'thumbUrl',
  'thumbnailUrl',
  'thumb',
  'imageUrl',
  'href',
  'rawUrl',
  'normalUrl',
  'hdUrl',
  'oriUrl',
  'url',
];
const _nestedKeys = <String>[
  'content',
  'attach',
  'attachment',
  'attachments',
  'photo',
  'photos',
  'media',
  'items',
  'data',
  'payload',
];

String zaloMessagePreview(ZaloMessage message) {
  return zaloMessageTextContent(message) ?? zaloMessageFallbackLabel(message);
}

String? zaloMessageTextContent(ZaloMessage message) {
  final content = message.content;
  if (content case final String text) {
    final normalized = _normalizeText(text);
    if (normalized != null) {
      return normalized;
    }
  }

  return _extractTextCandidate(content) ??
      _extractTextCandidate(message.propertyExt);
}

String? zaloMessageMediaPreviewUrl(ZaloMessage message) {
  if (!isZaloPreviewableMediaType(message.msgType)) {
    return null;
  }

  return _extractMediaUrl(message.content) ??
      _extractMediaUrl(message.propertyExt);
}

String zaloMessageFallbackLabel(ZaloMessage message) {
  switch (message.msgType) {
    case 'chat.photo':
      return '[Ảnh]';
    case 'chat.video.msg':
      return '[Video]';
    case 'share.file':
      return '[Tệp đính kèm]';
    case 'chat.sticker':
      return '[Sticker]';
    case 'chat.voice':
      return '[Tin nhắn thoại]';
    default:
      return '[${message.msgType.isEmpty ? 'Tin nhắn' : message.msgType}]';
  }
}

bool isZaloPreviewableMediaType(String msgType) {
  return _previewableMediaTypes.contains(msgType);
}

String? _extractTextCandidate(Object? value) {
  if (value is String) {
    final decoded = _tryDecodeJson(value);
    return decoded == null ? null : _extractTextCandidate(decoded);
  }

  if (value is List) {
    for (final item in value) {
      final candidate = _extractTextCandidate(item);
      if (candidate != null) {
        return candidate;
      }
    }
    return null;
  }

  if (value is! Map) {
    return null;
  }

  for (final key in _captionKeys) {
    final candidate = _normalizeText(value[key]);
    if (candidate != null) {
      return candidate;
    }
  }

  for (final key in _nestedKeys) {
    final candidate = _extractTextCandidate(value[key]);
    if (candidate != null) {
      return candidate;
    }
  }

  for (final entry in value.values) {
    if (entry is Map || entry is List) {
      final candidate = _extractTextCandidate(entry);
      if (candidate != null) {
        return candidate;
      }
    }
  }

  return null;
}

String? _extractMediaUrl(Object? value) {
  if (value is String) {
    final normalized = value.trim();
    if (_looksLikeRemoteUrl(normalized)) {
      return normalized;
    }

    final decoded = _tryDecodeJson(normalized);
    return decoded == null ? null : _extractMediaUrl(decoded);
  }

  if (value is List) {
    for (final item in value) {
      final candidate = _extractMediaUrl(item);
      if (candidate != null) {
        return candidate;
      }
    }
    return null;
  }

  if (value is! Map) {
    return null;
  }

  for (final key in _mediaKeys) {
    final candidate = _normalizeUrl(value[key]);
    if (candidate != null) {
      return candidate;
    }
  }

  for (final key in _nestedKeys) {
    final candidate = _extractMediaUrl(value[key]);
    if (candidate != null) {
      return candidate;
    }
  }

  for (final entry in value.values) {
    if (entry is Map || entry is List || entry is String) {
      final candidate = _extractMediaUrl(entry);
      if (candidate != null) {
        return candidate;
      }
    }
  }

  return null;
}

Object? _tryDecodeJson(String value) {
  final normalized = value.trim();
  if (!(normalized.startsWith('{') || normalized.startsWith('['))) {
    return null;
  }

  try {
    return jsonDecode(normalized);
  } catch (_) {
    return null;
  }
}

String? _normalizeText(Object? value) {
  if (value is! String) {
    return null;
  }

  final normalized = value.trim();
  if (normalized.isEmpty || _looksLikeRemoteUrl(normalized)) {
    return null;
  }

  return normalized;
}

String? _normalizeUrl(Object? value) {
  if (value is! String) {
    return null;
  }

  final normalized = value.trim();
  return _looksLikeRemoteUrl(normalized) ? normalized : null;
}

bool _looksLikeRemoteUrl(String value) {
  return value.startsWith('http://') || value.startsWith('https://');
}
