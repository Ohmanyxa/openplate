import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pairing.dart';
import 'setup_help.dart';
import 'connection_url.dart';
import 'app_ui.dart';
import 'vehicle_profiles_screen.dart';

class OpenPlateSettings {
  const OpenPlateSettings({
    required this.recognitionUrl,
    required this.homeAssistantWebhookUrl,
    required this.deviceId,
    required this.captureIntervalSeconds,
    required this.apiKey,
    required this.webhookSecret,
    this.registeredPlates = const {},
    this.supportsVehicleVerification = false,
    this.supportsWebRTC = false,
    this.liveCamera = const LiveCameraSettings(),
  });

  static const _secureStorage = FlutterSecureStorage();

  final String recognitionUrl;
  final String homeAssistantWebhookUrl;
  final String deviceId;
  final int captureIntervalSeconds;
  final String apiKey;
  final String webhookSecret;
  final Map<String, String> registeredPlates;
  final bool supportsVehicleVerification;
  final bool supportsWebRTC;
  final LiveCameraSettings liveCamera;

  factory OpenPlateSettings.fromPairing(
    OpenPlatePairingConfiguration configuration,
  ) => OpenPlateSettings(
    recognitionUrl: configuration.recognitionUrl,
    homeAssistantWebhookUrl: configuration.homeAssistantWebhookUrl,
    deviceId: configuration.deviceId,
    captureIntervalSeconds: configuration.captureIntervalSeconds,
    apiKey: configuration.recognitionApiKey,
    webhookSecret: configuration.webhookSecret,
    registeredPlates: configuration.registeredPlates,
    supportsVehicleVerification: configuration.supportsVehicleVerification,
    supportsWebRTC: configuration.supportsWebRTC,
    liveCamera: configuration.liveCamera,
  );

  bool get isPaired =>
      isHomeAssistantUrl(Uri.tryParse(homeAssistantWebhookUrl) ?? Uri()) &&
      deviceId.isNotEmpty &&
      webhookSecret.length >= 32;

  // Recognition runs on the device; legacy server fields are ignored.
  bool get isComplete => isPaired;

  String? get homeAssistantBaseUrl {
    final uri = Uri.tryParse(homeAssistantWebhookUrl);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      return null;
    }
    const webhookPath = '/api/webhook/';
    final marker = uri.path.lastIndexOf(webhookPath);
    if (marker < 0 || uri.path.substring(marker + webhookPath.length).isEmpty) {
      return null;
    }
    final base = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path.substring(0, marker),
    );
    return isHomeAssistantUrl(base) ? base.toString() : null;
  }

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
      registeredPlates: Map<String, String>.from(
        jsonDecode(await _secureStorage.read(key: 'registered_plates') ?? '{}')
            as Map,
      ),
      supportsVehicleVerification: preferences.getBool('vehicle_v1') ?? false,
      supportsWebRTC: preferences.getBool('camera_webrtc_v1') ?? false,
      liveCamera: LiveCameraSettings.fromJson(
        jsonDecode(preferences.getString('live_camera') ?? 'null'),
      ),
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
    await _secureStorage.write(
      key: 'registered_plates',
      value: jsonEncode(registeredPlates),
    );
    await preferences.setBool('vehicle_v1', supportsVehicleVerification);
    await preferences.setBool('camera_webrtc_v1', supportsWebRTC);
    await preferences.setString('live_camera', jsonEncode(liveCamera.toJson()));
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

  @override
  Widget build(BuildContext context) {
    final settings = widget.initial;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Einstellungen')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              SettingsSection(
                title: 'VERBINDUNG',
                children: [
                  ListTile(
                    leading: const Icon(Icons.home_outlined),
                    title: const Text('Home Assistant'),
                    subtitle: Text(
                      settings.isPaired
                          ? 'Kopplung gespeichert'
                          : 'Nicht gekoppelt',
                    ),
                  ),
                  if (settings.homeAssistantBaseUrl != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      child: SelectableText(
                        settings.homeAssistantBaseUrl!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: FilledButton.tonalIcon(
                      onPressed: _scanPairingCode,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                      label: Text(
                        settings.isPaired
                            ? 'iPhone neu koppeln'
                            : 'QR-Code scannen',
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'Der Scan übernimmt Adresse und Schlüssel automatisch. Keine manuelle Eingabe von Zugangsdaten nötig.',
                    ),
                  ),
                ],
              ),
              SettingsSection(
                title: 'ERKENNUNG',
                children: [
                  const ListTile(
                    leading: Icon(Icons.memory_rounded),
                    title: Text('Lokale Kennzeichenerkennung'),
                    subtitle: Text(
                      'YOLO + PaddleOCR Latin · Zeichensatz mit Ä, Ö und Ü.',
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.timer_outlined),
                    title: const Text('Prüfintervall'),
                    trailing: Text('${settings.captureIntervalSeconds} s'),
                    subtitle: const Text('Wird in Home Assistant eingestellt.'),
                  ),
                  const ListTile(
                    leading: Icon(Icons.badge_outlined),
                    title: Text('Kennzeichen & Automationen'),
                    subtitle: Text(
                      'Kennzeichen in Home Assistant verwalten. Dort stehen Anwesenheit und Bewegungsrichtung als Sensoren bereit.',
                    ),
                  ),
                ],
              ),
              if (settings.supportsWebRTC)
                SettingsSection(
                  title: 'LIVEBILD',
                  children: [
                    ListTile(
                      leading: const Icon(Icons.videocam_outlined),
                      title: const Text('H.264 / WebRTC'),
                      subtitle: Text(
                        '${settings.liveCamera.enabled ? "In HA aktiviert" : "In HA ausgeschaltet"} · '
                        '${settings.liveCamera.fps} FPS Ziel · ${settings.liveCamera.resolution}. '
                        'Ein/Aus, Bildrate und Auflösung unter OpenPlate → Konfigurieren → Kamera und Verbindung → Livebild einstellen.',
                      ),
                    ),
                  ],
                ),
              SettingsSection(
                title: 'BETRIEB & DATENSCHUTZ',
                children: [
                  const ListTile(
                    leading: Icon(Icons.play_circle_outline),
                    title: Text('Automatischer Start'),
                    subtitle: Text(
                      'Mit gespeicherter Kopplung starten Kamera und Erkennung beim Öffnen automatisch. '
                      'Das Livebild folgt der HA-Einstellung. Im Hintergrund oder bei gesperrtem iPhone '
                      'pausiert die Kamera; beim Zurückkehren läuft sie automatisch weiter.',
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.dark_mode_outlined),
                    title: Text('Schwarzmodus'),
                    subtitle: Text(
                      'Direkt in der Live-Kamera aktivieren. Die App muss sichtbar im Vordergrund bleiben.',
                    ),
                  ),
                  const ListTile(
                    leading: Icon(Icons.lock_outline_rounded),
                    title: Text('Verschlüsselte Übertragung'),
                    subtitle: Text(
                      'Kennzeichen, Bewegungsdaten und ein optional aktiviertes Livebild werden verschlüsselt an Home Assistant gesendet. Schlüssel liegen im iOS-Schlüsselbund.',
                    ),
                  ),
                  if (settings.isPaired)
                    ListTile(
                      leading: const Icon(Icons.phone_iphone_rounded),
                      title: const Text('Geräte-ID'),
                      subtitle: Text(settings.deviceId),
                    ),
                ],
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.code_rounded),
                title: const Text('Open-Source-Lizenzen'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: 'OpenPlate',
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.directions_car_outlined),
                title: const Text('Fahrzeugprofile & Einlernen'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => VehicleProfilesScreen(settings: settings),
                  ),
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.help_outline_rounded),
                title: const Text('Einrichtung & Hilfe'),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SetupHelpScreen(
                      homeAssistantUrl: settings.homeAssistantBaseUrl,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
