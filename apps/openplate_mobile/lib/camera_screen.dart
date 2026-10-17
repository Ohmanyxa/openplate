import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'openplate_api.dart';
import 'settings.dart';
import 'video_frame.dart';
import 'local_recognition.dart';

/// Frames never leave the device. Only confirmed strings go to paired HA.
class CameraScreen extends StatefulWidget {
  const CameraScreen({
    required this.cameras,
    required this.settings,
    this.apiFactory,
    this.recognizer,
    super.key,
  });

  final List<CameraDescription> cameras;
  final OpenPlateSettings settings;
  final OpenPlateApi Function(OpenPlateSettings)? apiFactory;
  final LocalPlateRecognizer? recognizer;

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void> _cameraTask = Future.value();
  int _generation = 0;
  int _processingEpoch = 0;
  late OpenPlateSettings _settings = widget.settings;
  late OpenPlateApi _api = _createApi(_settings);
  late final LocalPlateRecognizer _local =
      widget.recognizer ?? LocalPlateRecognizer();
  final _confirmation = LocalTemporalConfirmation();
  bool _startingRecognition = false;
  bool _modelsReady = false;
  bool _sendingEvents = false;

  OpenPlateApi _createApi(OpenPlateSettings settings) =>
      widget.apiFactory?.call(settings) ?? OpenPlateApi(settings);
  final Stopwatch _videoClock = Stopwatch()..start();
  Duration? _lastFrame;
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
  String? _rawReading;
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
    _processingEpoch++;
    _confirmation.reset();
    _pendingEvents.clear();
    _lastFrame = null;
    _cameraTask = _cameraTask.then((_) async {
      final previous = _controller;
      _controller = null;
      if (mounted) setState(() {});
      try {
        try {
          if (previous?.value.isStreamingImages ?? false) {
            await previous!.stopImageStream();
          }
        } finally {
          await previous?.dispose();
        }
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
          fps: 10,
          enableAudio: false,
          imageFormatGroup: Platform.isIOS
              ? ImageFormatGroup.bgra8888
              : ImageFormatGroup.yuv420,
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
        await controller.startImageStream(_onVideoFrame);
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
        _resetFrameAdmission();
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

  void _resetFrameAdmission() {
    _processingEpoch++;
    _confirmation.reset();
    _pendingEvents.clear();
    _lastFrame = null;
  }

  void _onVideoFrame(CameraImage image) {
    if (_busy || !_recognizing || !_foreground || !_settings.isComplete) return;
    final now = _videoClock.elapsed;
    if (_lastFrame != null &&
        now - _lastFrame! <
            Duration(seconds: _settings.captureIntervalSeconds)) {
      return;
    }
    _lastFrame = now;
    unawaited(_processFrame(VideoFrame(image)));
  }

  Future<void> _toggleRecognition() async {
    if (!_settings.isComplete || _controller == null || _startingRecognition) {
      return;
    }
    if (!_recognizing && !_modelsReady) {
      setState(() {
        _startingRecognition = true;
        _recognitionStatus =
            'Lokale Modelle werden geladen. Erster Start benötigt Internet (ca. 11 MB).';
      });
      try {
        await _local.initialize();
        _modelsReady = true;
      } on Object catch (error) {
        if (mounted) {
          setState(() {
            _startingRecognition = false;
            _recognitionStatus = error is PlatformException
                ? error.message ??
                      'Lokale Modelle konnten nicht gestartet werden'
                : 'Lokale Erkennung nicht verfügbar. iOS-App verwenden und Modell-Download prüfen.';
          });
        }
        return;
      }
      if (!mounted) return;
      _startingRecognition = false;
      if (!_foreground || _controller == null) {
        setState(
          () =>
              _recognitionStatus = 'Lokale Modelle bereit · Erkennung starten',
        );
        return;
      }
    }
    setState(() {
      _recognizing = !_recognizing;
      _recognitionStatus = _recognizing
          ? 'Lokale Erkennung aktiv · ONNX Runtime / iPhone CPU'
          : 'Erkennung ausgeschaltet';
    });
    _resetFrameAdmission();
  }

  Future<void> _processFrame(VideoFrame frame) async {
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
    final epoch = _processingEpoch;
    try {
      final readings = await _local.recognize(frame);
      if (!mounted ||
          !_recognizing ||
          !_foreground ||
          epoch != _processingEpoch ||
          generation != _generation) {
        return;
      }
      final api = _api;
      _rawReading = readings.isEmpty
          ? null
          : '${readings.first.plate} (${(readings.first.confidence * 100).toStringAsFixed(0)} %)';
      final result = _confirmation.update(readings, _videoClock.elapsed);
      for (final plate in result) {
        // Coalesce presence refreshes; never replay an outage as a queue of arrivals.
        _pendingEvents.removeWhere((event) => event.plate.plate == plate.plate);
        // A network outage must not create an unbounded event queue.
        if (_pendingEvents.length >= 100) {
          _pendingEvents.removeAt(0);
          _droppedEvents++;
        }
        _pendingEvents.add(PendingPlateEvent.fromPlate(plate));
        _lastPlate = plate.plate;
      }
      unawaited(_flushPending(api));
      if (mounted && _recognizing && _foreground && generation == _generation) {
        setState(
          () => _recognitionStatus =
              'Lokal · ${readings.length} gelesen · ${result.length} bestätigt · ${_pendingEvents.length} ausstehend'
              '${_droppedEvents > 0 ? ' · $_droppedEvents verworfen' : ''}',
        );
      }
    } on Object {
      if (mounted && _recognizing && _foreground && generation == _generation) {
        setState(
          () => _recognitionStatus =
              'Lokale Erkennung fehlgeschlagen – Kamera-/Modellformat prüfen',
        );
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _flushPending(OpenPlateApi api) async {
    if (_sendingEvents) return;
    _sendingEvents = true;
    try {
      for (final event in List<PendingPlateEvent>.of(_pendingEvents)) {
        if (!mounted || !_recognizing || !_foreground) return;
        if (DateTime.now().toUtc().difference(event.createdAt) >
            const Duration(seconds: 10)) {
          _pendingEvents.remove(event);
          _droppedEvents++;
          continue;
        }
        try {
          await api.sendHomeAssistantEvent(event);
          _pendingEvents.remove(event);
        } on Exception {
          return;
        }
      }
    } finally {
      _sendingEvents = false;
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
                                      'Home Assistant per QR-Code koppeln. Die Erkennung läuft lokal.',
                          ),
                          if (_lastPlate != null)
                            Text('Zuletzt bestätigt: $_lastPlate'),
                          if (_rawReading != null)
                            Text(
                              'OCR-Rohwert (nicht automatisch bestätigt): $_rawReading',
                            ),
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
                          onPressed:
                              _settings.isComplete &&
                                  controller != null &&
                                  !_startingRecognition
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
