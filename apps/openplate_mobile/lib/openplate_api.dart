import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'pairing.dart';
import 'settings.dart';
import 'encryption.dart';
import 'connection_url.dart';

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
  OpenPlateApi(this.settings, {http.Client? client}) : _client = client;

  final OpenPlateSettings settings;
  final http.Client? _client;
  String? _sessionId;

  Future<OpenPlateSettings> refreshConfiguration() async {
    final body = {
      'schema_version': 1,
      'event_type': 'device.configuration',
      'device_id': settings.deviceId,
    };
    final response = await _encryptedPost(body);
    if (response.statusCode != 200) {
      throw HttpException('Home Assistant ${response.statusCode}');
    }
    final configuration = OpenPlatePairingConfiguration.fromJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (configuration.deviceId != settings.deviceId) {
      throw const FormatException('Unerwartete Geräte-ID');
    }
    final sessionId =
        (jsonDecode(response.body) as Map<String, dynamic>)['session_id'];
    if (sessionId is! String || sessionId.length < 16) {
      throw const FormatException('Ungültige Verbindungssitzung');
    }
    _sessionId = sessionId;
    return OpenPlateSettings.fromPairing(configuration);
  }

  Future<void> sendHomeAssistantEvent(PendingPlateEvent event) async {
    if (_sessionId == null) await refreshConfiguration();
    final plate = event.plate;
    final body = <String, dynamic>{
      'schema_version': 1,
      'event_id': event.eventId,
      'device_id': settings.deviceId,
      'timestamp': event.createdAt.toIso8601String(),
      'event_type': 'plate.observed',
      'plate': plate.plate,
      'confidence': plate.confidence,
      'observations': plate.observations,
      'session_id': _sessionId,
    };
    var response = await _encryptedPost(body);
    if (response.statusCode == 428) {
      await refreshConfiguration();
      body['session_id'] = _sessionId;
      response = await _encryptedPost(body);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Home Assistant ${response.statusCode}');
    }
    if (jsonDecode(response.body)['accepted'] != true) {
      throw const FormatException(
        'Home Assistant hat das Ereignis nicht bestätigt',
      );
    }
  }

  Future<http.Response> _encryptedPost(Map<String, dynamic> body) async {
    final uri = Uri.parse(settings.homeAssistantWebhookUrl);
    if (!isHomeAssistantUrl(uri)) {
      throw const FormatException('Ungültige HA-Adresse');
    }
    final webhookId = uri.pathSegments.last;
    final envelope = await EncryptedTransport.seal(
      body,
      settings.webhookSecret,
      'device/request/$webhookId',
    );
    final client = _client ?? http.Client();
    try {
      final request = http.Request('POST', uri)
        ..followRedirects = false
        ..headers[HttpHeaders.contentTypeHeader] = 'application/json'
        ..body = jsonEncode(envelope);
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 10));
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 10));
      final payload = await EncryptedTransport.unseal(
        jsonDecode(response.body),
        settings.webhookSecret,
        'device/response/$webhookId/${envelope['id']}/${response.statusCode}',
      );
      return http.Response(jsonEncode(payload), response.statusCode);
    } finally {
      if (_client == null) client.close();
    }
  }
}
