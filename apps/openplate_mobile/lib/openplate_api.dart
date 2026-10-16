import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'settings.dart';

class ConfirmedPlate {
  const ConfirmedPlate({
    required this.plate,
    required this.confidence,
    required this.observations,
    required this.newEvent,
  });

  final String plate;
  final double confidence;
  final int observations;
  final bool newEvent;

  factory ConfirmedPlate.fromJson(Map<String, dynamic> json) => ConfirmedPlate(
    plate: json['plate'] as String,
    confidence: (json['confidence'] as num).toDouble(),
    observations: json['observations'] as int,
    newEvent: json['new_event'] as bool,
  );
}

class PendingPlateEvent {
  PendingPlateEvent.fromPlate(this.plate)
    : eventId = const Uuid().v4(),
      createdAt = DateTime.now().toUtc();

  final ConfirmedPlate plate;
  final String eventId;
  final DateTime createdAt;
}

class OpenPlateApi {
  OpenPlateApi(this.settings);

  final OpenPlateSettings settings;
  Future<List<ConfirmedPlate>> recognize(String imagePath) async {
    final request =
        http.MultipartRequest(
            'POST',
            Uri.parse('${settings.recognitionUrl}/v1/recognize'),
          )
          ..headers['X-OpenPlate-Api-Key'] = settings.apiKey
          ..fields['device_id'] = settings.deviceId
          ..files.add(await http.MultipartFile.fromPath('image', imagePath));
    final streamed = await request.send().timeout(const Duration(seconds: 20));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200) {
      throw HttpException('Erkennungsserver ${response.statusCode}');
    }
    final payload = jsonDecode(response.body) as Map<String, dynamic>;
    return (payload['plates'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map(ConfirmedPlate.fromJson)
        .toList(growable: false);
  }

  Future<void> sendHomeAssistantEvent(PendingPlateEvent event) async {
    final plate = event.plate;
    final body = jsonEncode({
      'schema_version': 1,
      'event_id': event.eventId,
      'device_id': settings.deviceId,
      'timestamp': event.createdAt.toIso8601String(),
      'event_type': 'plate.observed',
      'plate': plate.plate,
      'confidence': plate.confidence,
      'observations': plate.observations,
    });
    final timestamp = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final message = '$timestamp\n${event.eventId}\n$body';
    final signature = Hmac(
      sha256,
      utf8.encode(settings.webhookSecret),
    ).convert(utf8.encode(message)).toString();
    final response = await http
        .post(
          Uri.parse(settings.homeAssistantWebhookUrl),
          headers: {
            HttpHeaders.contentTypeHeader: 'application/json',
            'X-OpenPlate-Timestamp': '$timestamp',
            'X-OpenPlate-Nonce': event.eventId,
            'X-OpenPlate-Signature': signature,
          },
          body: body,
        )
        .timeout(const Duration(seconds: 10));
    // 409 means Home Assistant already accepted this stable event ID but its
    // original response was lost. Treat that replay-safe retry as delivered.
    if ((response.statusCode < 200 || response.statusCode >= 300) &&
        response.statusCode != 409) {
      throw HttpException('Home Assistant ${response.statusCode}');
    }
  }
}
