import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

class OpenPlatePairingRequest {
  const OpenPlatePairingRequest({
    required this.pairingUrl,
    required this.token,
    required this.expiresAt,
  });

  final Uri pairingUrl;
  final String token;
  final DateTime expiresAt;

  factory OpenPlatePairingRequest.parse(String raw, {DateTime? now}) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'openplate' || uri.host != 'pair') {
      throw const FormatException('Kein OpenPlate-Kopplungscode');
    }
    final values = uri.queryParameters;
    final pairingUrl = Uri.tryParse(values['pairing_url'] ?? '');
    final token = values['token'] ?? '';
    final expiresSeconds = int.tryParse(values['expires_at'] ?? '');
    if (values['version'] != '1') {
      throw const FormatException('Nicht unterstützte Code-Version');
    }
    if (pairingUrl == null ||
        pairingUrl.scheme != 'https' ||
        pairingUrl.host.isEmpty ||
        token.length < 32 ||
        expiresSeconds == null) {
      throw const FormatException(
        'Unvollständiger oder unsicherer Kopplungscode',
      );
    }
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(
      expiresSeconds * 1000,
      isUtc: true,
    );
    if (!expiresAt.isAfter((now ?? DateTime.now()).toUtc())) {
      throw const FormatException('Der Kopplungscode ist abgelaufen');
    }
    return OpenPlatePairingRequest(
      pairingUrl: pairingUrl,
      token: token,
      expiresAt: expiresAt,
    );
  }

  Future<OpenPlatePairingConfiguration> exchange({http.Client? client}) async {
    final ownedClient = client ?? http.Client();
    try {
      final response = await ownedClient
          .post(
            pairingUrl,
            headers: const {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode({'token': token}),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw FormatException(
          response.statusCode == 401
              ? 'Kopplungscode ungültig oder bereits verwendet'
              : 'Home Assistant antwortet mit ${response.statusCode}',
        );
      }
      final payload = jsonDecode(response.body);
      if (payload is! Map<String, dynamic>) {
        throw const FormatException('Ungültige Home-Assistant-Antwort');
      }
      return OpenPlatePairingConfiguration.fromJson(payload);
    } finally {
      if (client == null) ownedClient.close();
    }
  }
}

class OpenPlatePairingConfiguration {
  const OpenPlatePairingConfiguration({
    required this.deviceId,
    required this.recognitionUrl,
    required this.recognitionApiKey,
    required this.homeAssistantWebhookUrl,
    required this.webhookSecret,
    required this.captureIntervalSeconds,
  });

  final String deviceId;
  final String recognitionUrl;
  final String recognitionApiKey;
  final String homeAssistantWebhookUrl;
  final String webhookSecret;
  final int captureIntervalSeconds;

  factory OpenPlatePairingConfiguration.fromJson(Map<String, dynamic> json) {
    final recognitionUrl = Uri.tryParse(
      json['recognition_url'] as String? ?? '',
    );
    final webhookUrl = Uri.tryParse(
      json['home_assistant_webhook_url'] as String? ?? '',
    );
    final deviceId = json['device_id'] as String? ?? '';
    final apiKey = json['recognition_api_key'] as String? ?? '';
    final secret = json['webhook_secret'] as String? ?? '';
    final interval = json['capture_interval_seconds'];
    if (json['schema_version'] != 1 ||
        recognitionUrl == null ||
        !((recognitionUrl.toString().isEmpty && apiKey.isEmpty) ||
            (recognitionUrl.scheme == 'https' &&
                recognitionUrl.host.isNotEmpty &&
                apiKey.isNotEmpty)) ||
        webhookUrl == null ||
        webhookUrl.scheme != 'https' ||
        webhookUrl.host.isEmpty ||
        deviceId.isEmpty ||
        secret.length < 32 ||
        interval is! int ||
        interval < 1 ||
        interval > 60) {
      throw const FormatException(
        'Home Assistant lieferte eine unvollständige Konfiguration',
      );
    }
    return OpenPlatePairingConfiguration(
      deviceId: deviceId,
      recognitionUrl: recognitionUrl.toString().replaceAll(RegExp(r'/$'), ''),
      recognitionApiKey: apiKey,
      homeAssistantWebhookUrl: webhookUrl.toString(),
      webhookSecret: secret,
      captureIntervalSeconds: interval,
    );
  }
}

class PairingScannerScreen extends StatefulWidget {
  const PairingScannerScreen({super.key});

  @override
  State<PairingScannerScreen> createState() => _PairingScannerScreenState();
}

class _PairingScannerScreenState extends State<PairingScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;
  String? _error;

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || capture.barcodes.isEmpty) return;
    final raw = capture.barcodes.first.rawValue;
    if (raw == null) return;
    setState(() {
      _handled = true;
      _error = null;
    });
    try {
      final request = OpenPlatePairingRequest.parse(raw);
      await _controller.stop();
      final configuration = await request.exchange();
      if (mounted) Navigator.of(context).pop(configuration);
    } on Object catch (error) {
      if (!mounted) return;
      await _controller.start();
      setState(() {
        _handled = false;
        _error = error is FormatException
            ? error.message.toString()
            : 'Sichere Kopplung fehlgeschlagen';
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home Assistant koppeln')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.greenAccent, width: 3),
                borderRadius: BorderRadius.circular(24),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                margin: const EdgeInsets.all(20),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_handled) ...[
                      const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Flexible(
                      child: Text(
                        _error ??
                            (_handled
                                ? 'Verschlüsselte Konfiguration wird übertragen …'
                                : 'Den OpenPlate-Code aus Home Assistant scannen.'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
