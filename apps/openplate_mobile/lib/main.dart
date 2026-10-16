import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'openplate_api.dart';
import 'settings.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await OpenPlateSettings.load();
    if (mounted) setState(() => _settings = settings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('OpenPlate Kamera')),
      body: Padding(
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
              'Der Monitoring-Modus hält die App im Vordergrund und deckt das Livebild '
              'mit einer schwarzen Fläche ab. iOS darf die App nicht gesperrt oder in den '
              'Hintergrund verschoben haben.',
              textAlign: TextAlign.center,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: widget.cameras.isEmpty || !settings.isComplete
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => MonitorScreen(
                          cameras: widget.cameras,
                          settings: settings,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.play_arrow),
              label: const Text('Monitoring starten'),
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
              label: const Text('Verbindung einrichten'),
            ),
          ],
        ),
      ),
    );
  }
}

class MonitorScreen extends StatefulWidget {
  const MonitorScreen({
    required this.cameras,
    required this.settings,
    super.key,
  });

  final List<CameraDescription> cameras;
  final OpenPlateSettings settings;

  @override
  State<MonitorScreen> createState() => _MonitorScreenState();
}

class _MonitorScreenState extends State<MonitorScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Timer? _timer;
  bool _busy = false;
  bool _controlsVisible = false;
  String _status = 'Kamera wird gestartet';
  String? _lastPlate;
  int _failures = 0;
  final List<PendingPlateEvent> _pendingEvents = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  Future<void> _start() async {
    await WakelockPlus.enable();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    final back = widget.cameras.where(
      (item) => item.lensDirection == CameraLensDirection.back,
    );
    final camera = back.isNotEmpty ? back.first : widget.cameras.first;
    final controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() => _status = 'Überwachung aktiv');
      await _capture();
      _timer = Timer.periodic(
        Duration(seconds: widget.settings.captureIntervalSeconds),
        (_) => _capture(),
      );
    } on CameraException catch (error) {
      if (mounted) {
        setState(() => _status = 'Kamerafehler: ${error.description}');
      }
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_busy || controller == null || !controller.value.isInitialized) return;
    _busy = true;
    XFile? picture;
    try {
      picture = await controller.takePicture();
      final api = OpenPlateApi(widget.settings);
      await _flushPending(api);
      final result = await api.recognize(picture.path);
      for (final plate in result.where((item) => item.newEvent)) {
        _pendingEvents.add(PendingPlateEvent.fromPlate(plate));
      }
      await _flushPending(api);
      _failures = 0;
      if (mounted) {
        setState(
          () => _status =
              'Online · ${result.length} bestätigt · ${_pendingEvents.length} ausstehend',
        );
      }
    } catch (error) {
      _failures += 1;
      if (mounted) setState(() => _status = 'Fehler ($_failures): $error');
    } finally {
      if (picture != null) {
        try {
          await File(picture.path).delete();
        } on FileSystemException {
          // The OS also clears the camera temp directory.
        }
      }
      _busy = false;
    }
  }

  Future<void> _flushPending(OpenPlateApi api) async {
    for (final event in List<PendingPlateEvent>.of(_pendingEvents)) {
      try {
        await api.sendHomeAssistantEvent(event);
        _pendingEvents.remove(event);
        _lastPlate = event.plate.plate;
      } on Exception {
        // Keep the stable event ID and retry during the next capture cycle.
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() => _status = 'Pausiert – App muss im Vordergrund bleiben');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _controller?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PopScope(
      canPop: _controlsVisible,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _controlsVisible = !_controlsVisible),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (controller != null && controller.value.isInitialized)
                CameraPreview(controller),
              const ColoredBox(color: Colors.black),
              if (_controlsVisible)
                SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          _status,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        if (_lastPlate != null)
                          Text('Letztes Kennzeichen: $_lastPlate'),
                        const Spacer(),
                        FilledButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Monitoring beenden'),
                        ),
                      ],
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
