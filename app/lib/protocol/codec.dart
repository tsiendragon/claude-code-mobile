import 'dart:convert';

import 'models.dart';

Object decodeBridgeMessage(String message) {
  final decoded = jsonDecode(message);
  if (decoded is! Map) {
    throw const FormatException('Bridge message must be a JSON object.');
  }

  final json = Map<String, Object?>.from(decoded);
  switch (json['type']) {
    case 'response':
      return BridgeResponse.fromJson(json);
    case 'event':
      return BridgeEventEnvelope.fromJson(json);
    default:
      throw FormatException('Unknown bridge message type: ${json['type']}');
  }
}

String encodeBridgeRequest({
  required String type,
  required String id,
  Map<String, Object?> data = const {},
}) {
  return jsonEncode({
    'type': type,
    'id': id,
    if (data.isNotEmpty) ...data,
  });
}
