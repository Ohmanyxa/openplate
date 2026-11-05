import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'pairing.dart';
import 'settings.dart';
import 'encryption.dart';
import 'connection_url.dart';
import 'plate_motion.dart';
import 'vehicle_verification.dart';

class ConfirmedPlate {
  const ConfirmedPlate({
    required this.plate,
    required this.confidence,
    required this.observations,
    required this.newEvent,
    this.motion,
    this.vehicle,
  });

  final String plate;
  final double confidence;
  final int observations;
  final bool newEvent;
  final PlateMotion? motion;
  final VehicleAssessment? vehicle;

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
  bool supportsCamera = false;
  bool _supportsMotion = false;
  bool _supportsVehicle = false;

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
    supportsCamera =
        (jsonDecode(response.body)['capabilities'] as List?)?.contains(
          'camera_jpeg_v1',
        ) ??
        false;
    _supportsMotion =
        (jsonDecode(response.body)['capabilities'] as List?)?.contains(
          'motion_v1',
        ) ??
        false;
    _supportsVehicle = configuration.supportsVehicleVerification;
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
      if (_supportsMotion && plate.motion != null)
        'motion': plate.motion!.toJson(),
      if (_supportsVehicle && plate.vehicle != null)
        'vehicle': plate.vehicle!.toJson(),
    };
    var response = await _encryptedPost(body);
    if (response.statusCode == 428) {
      await refreshConfiguration();
      body['session_id'] = _sessionId;
      if (!_supportsMotion) body.remove('motion');
      if (!_supportsVehicle) body.remove('vehicle');
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

  Future<void> sendCameraFrame(Uint8List? jpeg, DateTime capturedAt) async {
    if (_sessionId == null) await refreshConfiguration();
    if (!supportsCamera) {
      throw const FormatException(
        'Home Assistant Integration für Livebild aktualisieren',
      );
    }
    if (jpeg != null && jpeg.length > 165000) {
      throw const FormatException('Kamerabild zu groß');
    }
    final body = <String, dynamic>{
      'schema_version': 1,
      'event_type': jpeg == null ? 'camera.stopped' : 'camera.frame',
      'device_id': settings.deviceId,
      'session_id': _sessionId,
      'timestamp': capturedAt.toUtc().toIso8601String(),
      if (jpeg != null) 'jpeg': base64Encode(jpeg),
    };
    final response = await _encryptedPost(body);
    if (response.statusCode == 428) {
      await refreshConfiguration();
      // Drop this frame: the next camera callback supplies a fresh image.
      throw const HttpException('Kamerasitzung erneuert');
    }
    if (response.statusCode != 200 ||
        jsonDecode(response.body)['accepted'] != true) {
      throw HttpException('Home Assistant Kamera: ${response.statusCode}');
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
