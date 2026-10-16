import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'openplate_api.dart';
import 'settings.dart';

/// Camera preview is local; frame uploads require an explicit recognition start.
class CameraScreen extends StatefulWidget {
  const CameraScreen({
    required this.cameras,
    required this.settings,
    this.apiFactory,
    super.key,
  });

  final List<CameraDescription> cameras;
  final OpenPlateSettings settings;
  final OpenPlateApi Function(OpenPlateSettings)? apiFactory;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _cameraTask = Future.value();
  Future<XFile>? _shutter;
  int _generation = 0;
  late OpenPlateSettings _settings = widget.settings;
  late OpenPlateApi _api = _createApi(_settings);

  OpenPlateApi _createApi(OpenPlateSettings settings) =>
      widget.apiFactory?.call(settings) ?? OpenPlateApi(settings);
  Timer? _captureTimer;
  Timer? _configurationTimer;
  Timer? _hideControlsTimer;
  bool _foreground = true;
  bool _recognizing = false;
  bool _busy = false;
  bool _refreshing = false;
  bool _blackMode = false;
  bool _controlsVisible = true;
  bool _cameraError = false;
  String _cameraStatus = 'Kamera wird gestartet';
  String _recognitionStatus = 'Erkennung ausgeschaltet';
  String _haStatus = 'Home Assistant noch nicht geprüft';
  String? _lastPlate;
  int _droppedEvents = 0;
  final List<PendingPlateEvent> _pendingEvents = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _queueCamera(_foreground);
    _updateScreenMode();
    unawaited(_refreshConfiguration());
    _configurationTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshConfiguration(),
    );
  }

  void _updateScreenMode() {
    unawaited(WakelockPlus.toggle(enable: _foreground));
    unawaited(
      SystemChrome.setEnabledSystemUIMode(
        _blackMode && _foreground
            ? SystemUiMode.immersiveSticky
            : SystemUiMode.edgeToEdge,
      ),
    );
  }

  void _queueCamera(bool open) {
    final generation = ++_generation;
    _captureTimer?.cancel();
    _cameraTask = _cameraTask.then((_) async {
      final previous = _controller;
      _controller = null;
      if (mounted) setState(() {});
      try {
        final shutter = _shutter;
        if (shutter != null) {
          try {
            await shutter.timeout(const Duration(seconds: 3));
          } on Object {
            // A suspended camera may abort a pending shutter operation.
          }
        }
        await previous?.dispose();
        if (!open || !mounted || generation != _generation) return;
        if (widget.cameras.isEmpty) {
          setState(() {
            _cameraError = true;
            _cameraStatus = 'Keine Kamera verfügbar';
          });
          return;
        }
        setState(() {
          _cameraError = false;
          _cameraStatus = 'Kamera wird gestartet';
        });
        final backs = widget.cameras.where(
          (camera) => camera.lensDirection == CameraLensDirection.back,
        );
        final controller = CameraController(
          backs.isEmpty ? widget.cameras.first : backs.first,
          ResolutionPreset.high,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.jpeg,
        );
        try {
          await controller.initialize();
        } on Object {
          await controller.dispose();
          rethrow;
        }
        if (!mounted || generation != _generation || !_foreground) {
          await controller.dispose();
          return;
        }
        setState(() {
          _controller = controller;
          _cameraStatus = 'Kamera aktiv';
        });
        _scheduleCaptures();
      } on Object catch (error) {
        if (mounted && generation == _generation) {
          setState(() {
            _cameraError = true;
            _cameraStatus = error is CameraException
                ? 'Kamerafehler: ${error.description ?? error.code}'
                : 'Kamera konnte nicht gestartet werden';
          });
        }
      }
    });
  }

  Future<void> _refreshConfiguration() async {
    if (!mounted || !_foreground || !_settings.isPaired || _refreshing) return;
    _refreshing = true;
    try {
      final updated = await _api.refreshConfiguration();
      if (!mounted) return;
      final changed =
          updated.recognitionUrl != _settings.recognitionUrl ||
          updated.apiKey != _settings.apiKey ||
          updated.captureIntervalSeconds != _settings.captureIntervalSeconds ||
          updated.homeAssistantWebhookUrl !=
              _settings.homeAssistantWebhookUrl ||
          updated.webhookSecret != _settings.webhookSecret;
      if (changed) {
        await updated.save();
        if (!mounted) return;
        _settings = updated;
        _api = _createApi(updated);
        if (!updated.isComplete) {
          _recognizing = false;
          _recognitionStatus = 'Erkennung ausgeschaltet';
        }
        _scheduleCaptures();
      }
      setState(() => _haStatus = 'Home Assistant verbunden');
    } on Object {
      if (mounted) {
        setState(
          () => _haStatus =
              'Home Assistant nicht erreichbar oder Kopplung noch nicht bestätigt',
        );
      }
    } finally {
      _refreshing = false;
    }
  }

  void _scheduleCaptures() {
    _captureTimer?.cancel();
    if (!_recognizing ||
        !_foreground ||
        !_settings.isComplete ||
        _controller == null) {
      return;
    }
    unawaited(_capture());
    _captureTimer = Timer.periodic(
      Duration(seconds: _settings.captureIntervalSeconds),
      (_) => _capture(),
    );
  }

  void _toggleRecognition() {
    if (!_settings.isComplete || _controller == null) return;
    setState(() {
      _recognizing = !_recognizing;
      _recognitionStatus = _recognizing
          ? 'Erkennung aktiv'
          : 'Erkennung ausgeschaltet';
    });
    _scheduleCaptures();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_busy ||
        !_recognizing ||
        !_foreground ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    _busy = true;
    final generation = _generation;
    XFile? picture;
    try {
      final shutter = controller.takePicture();
      _shutter = shutter;
      try {
        picture = await shutter;
      } finally {
        if (identical(_shutter, shutter)) _shutter = null;
      }
      if (!mounted ||
          !_recognizing ||
          !_foreground ||
          generation != _generation) {
        return;
      }
      final api = _api;
      await _flushPending(api);
      if (!mounted ||
          !_recognizing ||
          !_foreground ||
          generation != _generation) {
        return;
      }
      final result = await api.recognize(picture.path);
      if (!mounted ||
          !_recognizing ||
          !_foreground ||
          generation != _generation) {
        return;
      }
      for (final plate in result.where((plate) => plate.newEvent)) {
        // A network outage must not create an unbounded event queue.
        if (_pendingEvents.length >= 100) {
          _pendingEvents.removeAt(0);
          _droppedEvents++;
        }
        _pendingEvents.add(PendingPlateEvent.fromPlate(plate));
        _lastPlate = plate.plate;
      }
      await _flushPending(api);
      if (mounted && _recognizing && _foreground && generation == _generation) {
        setState(
          () => _recognitionStatus =
              'Erkennung aktiv · ${result.length} bestätigt · ${_pendingEvents.length} ausstehend'
              '${_droppedEvents > 0 ? ' · $_droppedEvents verworfen' : ''}',
        );
      }
    } on Object {
      if (mounted && _recognizing && _foreground && generation == _generation) {
        setState(
          () => _recognitionStatus =
              'Erkennung fehlgeschlagen – Serververbindung prüfen',
        );
      }
    } finally {
      if (picture != null) {
        try {
          await File(picture.path).delete();
        } on FileSystemException {
          // The OS also clears the camera's temporary files.
        }
      }
      _busy = false;
    }
  }

  Future<void> _flushPending(OpenPlateApi api) async {
    for (final event in List<PendingPlateEvent>.of(_pendingEvents)) {
      if (!mounted || !_recognizing || !_foreground) return;
      try {
        await api.sendHomeAssistantEvent(event);
        _pendingEvents.remove(event);
      } on Exception {
        return;
      }
    }
  }

  void _toggleBlackMode() {
    _hideControlsTimer?.cancel();
    setState(() {
      _blackMode = !_blackMode;
      _controlsVisible = !_blackMode;
    });
    _updateScreenMode();
  }

  void _revealControls() {
    if (!_blackMode) return;
    _hideControlsTimer?.cancel();
    setState(() => _controlsVisible = true);
    _hideControlsTimer = Timer(const Duration(seconds: 8), () {
      if (mounted && _blackMode) setState(() => _controlsVisible = false);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _foreground) return;
    _foreground = foreground;
    _queueCamera(foreground);
    _updateScreenMode();
    if (foreground) {
      unawaited(_refreshConfiguration());
    } else {
      setState(() => _cameraStatus = 'Pausiert – App im Vordergrund öffnen');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _configurationTimer?.cancel();
    _hideControlsTimer?.cancel();
    _foreground = false;
    _queueCamera(false);
    unawaited(WakelockPlus.disable());
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return PopScope(
      canPop: !_blackMode || _controlsVisible,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _revealControls,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!_blackMode &&
                  controller != null &&
                  controller.value.isInitialized)
                Center(child: CameraPreview(controller)),
              if (_blackMode)
                const ColoredBox(
                  key: Key('all-black-screen'),
                  color: Colors.black,
                ),
              if (!_blackMode || _controlsVisible)
                SafeArea(child: _buildControls(controller)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls(CameraController? controller) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Material(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_cameraStatus),
                          Text(
                            _settings.isPaired
                                ? _haStatus
                                : 'Home Assistant nicht gekoppelt',
                          ),
                          Text(
                            _settings.isComplete
                                ? _recognitionStatus
                                : 'Nur Live-Vorschau · keine Bildübertragung. '
                                      'Erkennungsserver in Home Assistant unter Konfigurieren einrichten.',
                          ),
                          if (_lastPlate != null)
                            Text('Letztes Kennzeichen: $_lastPlate'),
                          if (_blackMode)
                            const Text(
                              'Bedienung wird nach 8 Sekunden ausgeblendet.',
                            ),
                        ],
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_cameraError)
                          FilledButton.icon(
                            onPressed: () => _queueCamera(_foreground),
                            icon: const Icon(Icons.refresh),
                            label: const Text('Kamera erneut starten'),
                          ),
                        FilledButton.icon(
                          onPressed: _settings.isComplete && controller != null
                              ? _toggleRecognition
                              : null,
                          icon: Icon(
                            _recognizing ? Icons.pause : Icons.play_arrow,
                          ),
                          label: Text(
                            _recognizing
                                ? 'Erkennung stoppen'
                                : 'Erkennung starten',
                          ),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonalIcon(
                          onPressed: _toggleBlackMode,
                          icon: Icon(
                            _blackMode ? Icons.visibility : Icons.dark_mode,
                          ),
                          label: Text(
                            _blackMode ? 'Vorschau anzeigen' : 'Schwarzmodus',
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Kamera schließen'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
