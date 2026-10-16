import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class OpenPlatePairing {
  const OpenPlatePairing({
    required this.deviceId,
    required this.homeAssistantWebhookUrl,
    required this.webhookSecret,
    required this.expiresAt,
  });

  final String deviceId;
  final String homeAssistantWebhookUrl;
  final String webhookSecret;
  final DateTime expiresAt;

  factory OpenPlatePairing.parse(String raw, {DateTime? now}) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'openplate' || uri.host != 'pair') {
      throw const FormatException('Kein OpenPlate-Kopplungscode');
    }
    final values = uri.queryParameters;
    if (values['version'] != '1') {
      throw const FormatException('Nicht unterstützte Code-Version');
    }
    final deviceId = values['device_id']?.trim() ?? '';
    final webhookUrl = Uri.tryParse(values['home_assistant_webhook_url'] ?? '');
    final secret = values['webhook_secret'] ?? '';
    final expiresSeconds = int.tryParse(values['expires_at'] ?? '');
    if (deviceId.isEmpty ||
        webhookUrl == null ||
        webhookUrl.scheme != 'https' ||
        webhookUrl.host.isEmpty ||
        secret.length < 32 ||
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
    return OpenPlatePairing(
      deviceId: deviceId,
      homeAssistantWebhookUrl: webhookUrl.toString(),
      webhookSecret: secret,
      expiresAt: expiresAt,
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
    try {
      final pairing = OpenPlatePairing.parse(raw);
      _handled = true;
      await _controller.stop();
      if (mounted) Navigator.of(context).pop(pairing);
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message.toString());
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
                child: Text(
                  _error ??
                      'Den in Home Assistant angezeigten OpenPlate-Code scannen.',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
