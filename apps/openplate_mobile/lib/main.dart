import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'camera_screen.dart';
import 'openplate_api.dart';
import 'settings.dart';
import 'app_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      ['Intel Open Model Zoo vehicles'],
      'Copyright (c) Intel Corporation.\n\n${await rootBundle.loadString('assets/licenses/Intel-OpenModelZoo-LICENSE')}',
    );
    yield LicenseEntryWithLineBreaks([
      'Vehicle ReID / OSNet',
    ], await rootBundle.loadString('assets/licenses/Vehicle-ReID-LICENSE'));
    yield LicenseEntryWithLineBreaks([
      'PaddleOCR Latin',
    ], await rootBundle.loadString('assets/licenses/PaddleOCR-LICENSE'));
  });
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
      debugShowCheckedModeBanner: false,
      theme: openPlateTheme(),
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
          !mapEquals(updated.registeredPlates, settings.registeredPlates) ||
          updated.supportsVehicleVerification !=
              settings.supportsVehicleVerification ||
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

  Future<void> _openSettings() async {
    final updated = await Navigator.of(context).push<OpenPlateSettings>(
      MaterialPageRoute(builder: (_) => SettingsScreen(initial: _settings!)),
    );
    if (updated != null && mounted) {
      setState(() {
        _settings = updated;
        _haVerified = false;
        _configurationError = null;
      });
      await _refreshConfiguration();
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
    return DashboardScreen(
      settings: settings,
      cameraAvailable: widget.cameras.isNotEmpty,
      verified: _haVerified,
      connectionError: _configurationError,
      onOpenCamera: _openCamera,
      onOpenSettings: _openSettings,
    );
  }
}

/// Presentation-only dashboard; one settings entry, one camera entry.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    required this.settings,
    required this.cameraAvailable,
    required this.verified,
    required this.onOpenCamera,
    required this.onOpenSettings,
    this.connectionError,
    super.key,
  });
  final OpenPlateSettings settings;
  final bool cameraAvailable, verified;
  final String? connectionError;
  final VoidCallback onOpenCamera, onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final linked = settings.isPaired;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'OpenPlate',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Einstellungen',
            onPressed: onOpenSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
            children: [
              Text(
                'DEIN LOKALER KENNZEICHEN-SENSOR',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  letterSpacing: 1.4,
                ),
              ),
              const SizedBox(height: 28),
              Text(
                cameraAvailable
                    ? 'Bereit für deine\nEinfahrt.'
                    : 'Kamera nicht verfügbar.',
                style: theme.textTheme.headlineLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Erkennen auf dem iPhone. Verbinden mit Home Assistant.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 28),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: .1,
                            ),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Icon(
                            Icons.videocam_outlined,
                            size: 36,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text('Live-Kamera', style: theme.textTheme.titleLarge),
                      const SizedBox(height: 8),
                      Text(
                        cameraAvailable
                            ? 'Vorschau zum Ausrichten, Schwarzmodus für den Dauerbetrieb.'
                            : 'Prüfe die Kameraberechtigung in iOS.',
                        style: TextStyle(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: cameraAvailable ? onOpenCamera : null,
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: const Text('Kamera öffnen'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        verified
                            ? Icons.check_circle_outline
                            : Icons.link_rounded,
                        color: verified
                            ? theme.colorScheme.primary
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Home Assistant',
                              style: theme.textTheme.titleMedium,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              verified
                                  ? 'Verbunden · verschlüsselt'
                                  : linked
                                  ? 'Kopplung gespeichert · Verbindung wird geprüft'
                                  : 'Noch nicht gekoppelt',
                              style: TextStyle(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (!linked)
                              const Padding(
                                padding: EdgeInsets.only(top: 8),
                                child: Text(
                                  'Kopple dein iPhone in den Einstellungen per QR-Code. Die Vorschau funktioniert auch ohne Verbindung.',
                                ),
                              ),
                            if (connectionError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(
                                  connectionError!,
                                  style: TextStyle(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.privacy_tip_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Die Erkennung läuft lokal. Kennzeichen und ein optional aktiviertes Livebild werden verschlüsselt an Home Assistant übertragen.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
