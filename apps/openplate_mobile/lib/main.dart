import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'camera_screen.dart';
import 'openplate_api.dart';
import 'pairing.dart';
import 'settings.dart';
import 'setup_help.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(OpenPlateApp(cameras: cameras));
}

class OpenPlateApp extends StatelessWidget {
  const OpenPlateApp({required this.cameras, super.key});

  final List<CameraDescription> cameras;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenPlate',
      theme: ThemeData(
        colorSchemeSeed: Colors.green,
        brightness: Brightness.dark,
      ),
      home: HomeScreen(cameras: cameras),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({required this.cameras, super.key});

  final List<CameraDescription> cameras;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  OpenPlateSettings? _settings;
  Timer? _configurationTimer;
  bool _refreshing = false;
  String? _configurationError;
  bool _cameraOpen = false;
  bool _haVerified = false;

  @override
  void initState() {
    super.initState();
    _load();
    _configurationTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshConfiguration(),
    );
  }

  Future<void> _load() async {
    final settings = await OpenPlateSettings.load();
    if (mounted) setState(() => _settings = settings);
    await _refreshConfiguration();
  }

  Future<void> _refreshConfiguration() async {
    final settings = _settings;
    if (!mounted ||
        settings == null ||
        !settings.isPaired ||
        _refreshing ||
        _cameraOpen) {
      return;
    }
    _refreshing = true;
    try {
      final updated = await OpenPlateApi(settings).refreshConfiguration();
      if (!mounted || !identical(settings, _settings)) return;
      if (updated.recognitionUrl != settings.recognitionUrl ||
          updated.apiKey != settings.apiKey ||
          updated.captureIntervalSeconds != settings.captureIntervalSeconds ||
          updated.homeAssistantWebhookUrl != settings.homeAssistantWebhookUrl ||
          updated.webhookSecret != settings.webhookSecret) {
        await updated.save();
        if (mounted && identical(settings, _settings)) {
          setState(() => _settings = updated);
        }
      }
      if (mounted) {
        setState(() {
          _configurationError = null;
          _haVerified = true;
        });
      }
    } on Object {
      if (mounted) {
        setState(() {
          _haVerified = false;
          _configurationError =
              'Home Assistant nicht erreichbar oder Kopplung noch nicht bestätigt.';
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    _configurationTimer?.cancel();
    super.dispose();
  }

  Future<void> _pair() async {
    final configuration = await Navigator.of(context)
        .push<OpenPlatePairingConfiguration>(
          MaterialPageRoute(builder: (_) => const PairingScannerScreen()),
        );
    if (configuration == null || !mounted) return;
    final settings = OpenPlateSettings.fromPairing(configuration);
    await settings.save();
    if (mounted) {
      setState(() {
        _settings = settings;
        _haVerified = false;
      });
    }
  }

  Future<void> _openCamera() async {
    final settings = _settings;
    if (settings == null) return;
    _cameraOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              CameraScreen(cameras: widget.cameras, settings: settings),
        ),
      );
    } finally {
      _cameraOpen = false;
      if (mounted) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('OpenPlate Kamera'),
        actions: [
          IconButton(
            tooltip: 'Hilfe beim Koppeln',
            icon: const Icon(Icons.help_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SetupHelpScreen(
                  homeAssistantUrl: settings.homeAssistantBaseUrl,
                ),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.videocam_outlined, size: 72),
              const SizedBox(height: 16),
              Text(
                'Montierte Kamera',
                style: Theme.of(context).textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Öffne die Live-Vorschau zum Ausrichten der Kamera. Im Schwarzmodus bleibt '
                'die Kamera aktiv und das Display schwarz. Die App muss im Vordergrund bleiben.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (settings.isPaired) ...[
                Text(
                  _haVerified
                      ? 'Home Assistant verbunden'
                      : 'Kopplung gespeichert',
                  textAlign: TextAlign.center,
                ),
                if (_configurationError != null)
                  Text(_configurationError!, textAlign: TextAlign.center),
                if (!settings.isComplete)
                  const Text(
                    'Erkennungsserver noch nicht eingerichtet. Die Live-Vorschau ist auch ohne '
                    'Server möglich. Für Kennzeichenerkennung den Server in Home Assistant unter '
                    'OpenPlate → Konfigurieren → Erkennungsserver einrichten hinterlegen.',
                    textAlign: TextAlign.center,
                  ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: widget.cameras.isEmpty ? null : _openCamera,
                icon: const Icon(Icons.videocam_outlined),
                label: const Text('Kamera öffnen'),
              ),
              if (widget.cameras.isEmpty)
                const Text(
                  'Keine Kamera verfügbar. Prüfe die Kameraberechtigung in iOS.',
                ),
              if (!settings.isPaired)
                FilledButton.icon(
                  onPressed: _pair,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('iPhone per QR-Code koppeln'),
                ),
              if (!settings.isPaired)
                TextButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SetupHelpScreen(),
                    ),
                  ),
                  icon: const Icon(Icons.help_outline),
                  label: const Text('Wo finde ich die benötigte Adresse?'),
                ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final updated = await Navigator.of(context)
                      .push<OpenPlateSettings>(
                        MaterialPageRoute(
                          builder: (_) => SettingsScreen(initial: settings),
                        ),
                      );
                  if (updated != null && mounted) {
                    setState(() => _settings = updated);
                  }
                },
                icon: const Icon(Icons.settings),
                label: Text(
                  settings.isPaired
                      ? 'Verbindung verwalten'
                      : 'Manuell einrichten',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
