import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pairing.dart';

class OpenPlateSettings {
  const OpenPlateSettings({
    required this.recognitionUrl,
    required this.homeAssistantWebhookUrl,
    required this.deviceId,
    required this.captureIntervalSeconds,
    required this.apiKey,
    required this.webhookSecret,
  });

  static const _secureStorage = FlutterSecureStorage();

  final String recognitionUrl;
  final String homeAssistantWebhookUrl;
  final String deviceId;
  final int captureIntervalSeconds;
  final String apiKey;
  final String webhookSecret;

  factory OpenPlateSettings.fromPairing(
    OpenPlatePairingConfiguration configuration,
  ) => OpenPlateSettings(
    recognitionUrl: configuration.recognitionUrl,
    homeAssistantWebhookUrl: configuration.homeAssistantWebhookUrl,
    deviceId: configuration.deviceId,
    captureIntervalSeconds: configuration.captureIntervalSeconds,
    apiKey: configuration.recognitionApiKey,
    webhookSecret: configuration.webhookSecret,
  );

  bool get isPaired =>
      homeAssistantWebhookUrl.startsWith('https://') &&
      deviceId.isNotEmpty &&
      webhookSecret.length >= 32;

  bool get isComplete =>
      isPaired && recognitionUrl.startsWith('https://') && apiKey.isNotEmpty;

  static Future<OpenPlateSettings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return OpenPlateSettings(
      recognitionUrl: preferences.getString('recognition_url') ?? '',
      homeAssistantWebhookUrl: preferences.getString('ha_webhook_url') ?? '',
      deviceId: preferences.getString('device_id') ?? 'iphone_gate',
      captureIntervalSeconds: preferences.getInt('capture_interval') ?? 1,
      apiKey: await _secureStorage.read(key: 'recognition_api_key') ?? '',
      webhookSecret:
          await _secureStorage.read(key: 'ha_webhook_secret') ?? _newSecret(),
    );
  }

  Future<void> save() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString('recognition_url', recognitionUrl);
    await preferences.setString('ha_webhook_url', homeAssistantWebhookUrl);
    await preferences.setString('device_id', deviceId);
    await preferences.setInt('capture_interval', captureIntervalSeconds);
    await _secureStorage.write(key: 'recognition_api_key', value: apiKey);
    await _secureStorage.write(key: 'ha_webhook_secret', value: webhookSecret);
  }

  static String _newSecret() {
    final random = Random.secure();
    return base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({required this.initial, super.key});

  final OpenPlateSettings initial;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _recognition;
  late final TextEditingController _webhook;
  late final TextEditingController _device;
  late final TextEditingController _interval;
  late final TextEditingController _apiKey;
  late final TextEditingController _secret;

  @override
  void initState() {
    super.initState();
    _recognition = TextEditingController(text: widget.initial.recognitionUrl);
    _webhook = TextEditingController(
      text: widget.initial.homeAssistantWebhookUrl,
    );
    _device = TextEditingController(text: widget.initial.deviceId);
    _interval = TextEditingController(
      text: '${widget.initial.captureIntervalSeconds}',
    );
    _apiKey = TextEditingController(text: widget.initial.apiKey);
    _secret = TextEditingController(text: widget.initial.webhookSecret);
  }

  String? _httpsUrl(String? value) {
    final uri = Uri.tryParse(value ?? '');
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? null
        : 'Eine vollständige HTTPS-URL eingeben';
  }

  Future<void> _scanPairingCode() async {
    final configuration = await Navigator.of(context)
        .push<OpenPlatePairingConfiguration>(
          MaterialPageRoute(builder: (_) => const PairingScannerScreen()),
        );
    if (configuration == null || !mounted) return;
    final settings = OpenPlateSettings.fromPairing(configuration);
    await settings.save();
    if (mounted) Navigator.of(context).pop(settings);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final settings = OpenPlateSettings(
      recognitionUrl: _recognition.text.trim().replaceAll(RegExp(r'/$'), ''),
      homeAssistantWebhookUrl: _webhook.text.trim(),
      deviceId: _device.text.trim(),
      captureIntervalSeconds: int.parse(_interval.text),
      apiKey: _apiKey.text,
      webhookSecret: _secret.text,
    );
    await settings.save();
    if (mounted) Navigator.of(context).pop(settings);
  }

  @override
  void dispose() {
    _recognition.dispose();
    _webhook.dispose();
    _device.dispose();
    _interval.dispose();
    _apiKey.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Verbindung')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FilledButton.tonalIcon(
              onPressed: _scanPairingCode,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Home-Assistant-QR-Code scannen'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ein Scan übernimmt die vollständige Konfiguration verschlüsselt '
              'von Home Assistant und speichert die Schlüssel im iOS-Schlüsselbund.',
              textAlign: TextAlign.center,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Divider(),
            ),
            TextFormField(
              controller: _recognition,
              decoration: const InputDecoration(
                labelText: 'Erkennungsserver',
                hintText: 'https://openplate.local',
              ),
              keyboardType: TextInputType.url,
              validator: _httpsUrl,
            ),
            TextFormField(
              controller: _apiKey,
              decoration: const InputDecoration(labelText: 'Server-API-Key'),
              obscureText: true,
              validator: (value) =>
                  (value ?? '').isEmpty ? 'API-Key eingeben' : null,
            ),
            TextFormField(
              controller: _webhook,
              decoration: const InputDecoration(
                labelText: 'Home-Assistant-Webhook',
                hintText: 'https://homeassistant.local/api/webhook/…',
              ),
              keyboardType: TextInputType.url,
              validator: _httpsUrl,
            ),
            TextFormField(
              controller: _secret,
              decoration: const InputDecoration(
                labelText: 'Webhook-Signaturschlüssel',
              ),
              obscureText: true,
              validator: (value) =>
                  (value ?? '').length < 32 ? 'Mindestens 32 Zeichen' : null,
            ),
            TextFormField(
              controller: _device,
              decoration: const InputDecoration(labelText: 'Geräte-ID'),
              validator: (value) =>
                  (value ?? '').trim().isEmpty ? 'Geräte-ID eingeben' : null,
            ),
            TextFormField(
              controller: _interval,
              decoration: const InputDecoration(
                labelText: 'Aufnahmeintervall (Sekunden)',
              ),
              keyboardType: TextInputType.number,
              validator: (value) {
                final parsed = int.tryParse(value ?? '');
                return parsed == null || parsed < 1 || parsed > 60
                    ? '1–60 Sekunden'
                    : null;
              },
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Speichern')),
          ],
        ),
      ),
    );
  }
}
