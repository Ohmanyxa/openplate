import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'openplate_api.dart';
import 'settings.dart';
import 'video_frame.dart';
import 'local_recognition.dart';
import 'plate_identity.dart';
import 'plate_motion.dart';
import 'vehicle_verification.dart';

/// Local recognition with an independently enabled encrypted HA live image.
class CameraScreen extends StatefulWidget {
  const CameraScreen({
    required this.cameras,
    required this.settings,
    this.apiFactory,
    this.recognizer,
    this.vehicleVerifierFactory,
    super.key,
  });

  final List<CameraDescription> cameras;
  final OpenPlateSettings settings;
  final OpenPlateApi Function(OpenPlateSettings)? apiFactory;
  final LocalPlateRecognizer? recognizer;
  final VehicleVerifier Function(OpenPlateSettings)? vehicleVerifierFactory;

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
  final _motion = PlateMotionTracker();
  (int, int)? _motionFrameSize;
  String _motionStatus = 'Richtung unbekannt';
  bool _startingRecognition = false;
  bool _modelsReady = false;
  bool _sendingEvents = false;
  bool _streaming = false;
  bool _liveImageEnabledOnce = false;
  bool _sendingFrame = false;
  bool _stoppingStream = false;
  Duration? _lastStreamFrame;
  String _streamStatus = 'Livebild ausgeschaltet';
  static const _cameraChannel = MethodChannel('openplate/local_recognition');

  Future<void> _sendLiveFrame(VideoFrame frame, int generation) async {
    _sendingFrame = true;
    final capturedAt = DateTime.now().toUtc();
    final api = _api;
    try {
      final jpeg = await _cameraChannel
          .invokeMethod<Uint8List>('encodeCameraFrame', {
            'bytes': frame.planes.single,
            'width': frame.width,
            'height': frame.height,
            'bytesPerRow': frame.strides.single,
            'orientation':
                _controller?.value.deviceOrientation.name ?? 'portraitUp',
          });
      if (!mounted ||
          !_streaming ||
          !_foreground ||
          generation != _generation ||
          jpeg == null) {
        return;
      }
      await api.sendCameraFrame(jpeg, capturedAt);
      if (mounted && _streaming) {
        setState(
          () => _streamStatus = 'Livebild verschlüsselt an Home Assistant',
        );
      }
    } on Object {
      if (mounted && _streaming) {
        setState(
          () => _streamStatus =
              'Livebild unterbrochen · Verbindung wird erneut versucht',
        );
      }
    } finally {
      _sendingFrame = false;
    }
  }

  Future<void> _stopLiveImage() async {
    if (_stoppingStream || !_liveImageEnabledOnce) return;
    _stoppingStream = true;
    // Wait for the one in-flight upload so a late frame cannot undo the stop.
    while (_sendingFrame) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    try {
      await _api.sendCameraFrame(null, DateTime.now().toUtc());
    } on Object {
      // HA expires the last image automatically after ten seconds.
    } finally {
      _stoppingStream = false;
    }
  }

  void _toggleLiveImage() {
    setState(() {
      _streaming = !_streaming;
      if (_streaming) _liveImageEnabledOnce = true;
      _streamStatus = _streaming
          ? 'Livebild wird verbunden'
          : 'Livebild ausgeschaltet';
      _lastStreamFrame = null;
    });
    if (!_streaming) unawaited(_stopLiveImage());
  }

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
  VehicleVerifier? _vehicleVerifier;
  final Map<String, VehicleEvidence> _vehicleCandidates = {};
  final Map<String, VehicleAssessment> _vehicleResults = {};
  final Map<String, ConfirmedPlate> _candidateProofs = {};
  bool _reviewingVehicle = false;

  Future<void> _configureVehicles() async {
    if (!_settings.supportsVehicleVerification) return;
    final verifier =
        widget.vehicleVerifierFactory?.call(_settings) ??
        VehicleVerifier(_settings);
    if (_vehicleVerifier?.scope != verifier.scope) _vehicleVerifier = verifier;
    await _vehicleVerifier!.load(_settings.registeredPlates.keys);
    await _local.configureVehicles(_settings.registeredPlates.keys);
  }

  Future<void> _reviewVehicle(String plate) async {
    final evidence = _vehicleCandidates[plate];
    final verifier = _vehicleVerifier;
    final proof = _candidateProofs[plate];
    if (_reviewingVehicle ||
        evidence == null ||
        verifier == null ||
        proof == null) {
      return;
    }
    _reviewingVehicle = true;
    var view = 'front';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text('Ist das dein Fahrzeug für $plate?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.memory(evidence.preview, gaplessPlayback: true),
                const SizedBox(height: 12),
                Text('${evidence.type} · ${evidence.color}'),
                const Text(
                  'Nur bestätigen, wenn Kennzeichen und vollständiges Fahrzeug zusammenpassen. '
                  'Der Ausschnitt bleibt nur kurz im Arbeitsspeicher; gespeichert wird der Merkmalsvektor.',
                ),
                DropdownButton<String>(
                  value: view,
                  isExpanded: true,
                  items: const [
                    DropdownMenuItem(
                      value: 'front',
                      child: Text('Frontansicht'),
                    ),
                    DropdownMenuItem(value: 'rear', child: Text('Heckansicht')),
                  ],
                  onChanged: (value) => update(() => view = value!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Nein'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Bestätigen'),
            ),
          ],
        ),
      ),
    );
    try {
      if (accepted == true &&
          mounted &&
          _foreground &&
          _recognizing &&
          identical(verifier, _vehicleVerifier) &&
          _settings.registeredPlates.containsKey(plate)) {
        await verifier.confirm(plate, evidence, view, DateTime.now().toUtc());
        final verdict = VehicleAssessment(
          'confirmed',
          type: evidence.type,
          color: evidence.color,
          referenceCount: verifier.profiles[plate]!.references.length,
        );
        _pendingEvents.removeWhere((event) => event.plate.plate == plate);
        _pendingEvents.add(
          PendingPlateEvent.fromPlate(
            ConfirmedPlate(
              plate: proof.plate,
              confidence: proof.confidence,
              observations: proof.observations,
              newEvent: true,
              vehicle: verdict,
            ),
          ),
        );
        unawaited(_flushPending(_api));
        if (mounted && verifier.profiles[plate]!.ready) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Referenzen bereit. Automatischen Vergleich unter Einstellungen → Fahrzeugprofile bewusst aktivieren.',
              ),
            ),
          );
        }
        if (mounted) {
          setState(() => _vehicleResults[plate] = verdict);
        }
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      _reviewingVehicle = false;
    }
  }

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
    _motion.reset();
    _pendingEvents.clear();
    _vehicleVerifier?.resetTransient();
    _vehicleCandidates.clear();
    _candidateProofs.clear();
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
          !mapEquals(updated.registeredPlates, _settings.registeredPlates) ||
          updated.supportsVehicleVerification !=
              _settings.supportsVehicleVerification ||
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
      await _configureVehicles();
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
    _motion.reset();
    _motionStatus = 'Richtung unbekannt';
    _pendingEvents.clear();
    _vehicleVerifier?.resetTransient();
    _vehicleCandidates.clear();
    _vehicleResults.clear();
    _candidateProofs.clear();
    _lastFrame = null;
  }

  void _onVideoFrame(CameraImage image) {
    final streamNow = _videoClock.elapsed;
    if (_streaming &&
        !_sendingFrame &&
        !_stoppingStream &&
        _foreground &&
        _settings.isPaired &&
        image.format.group == ImageFormatGroup.bgra8888 &&
        (_lastStreamFrame == null ||
            streamNow - _lastStreamFrame! >=
                const Duration(milliseconds: 500))) {
      _lastStreamFrame = streamNow;
      unawaited(_sendLiveFrame(VideoFrame(image), _generation));
    }
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
        await _configureVehicles();
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
    final frameReceiptAt = _videoClock.elapsed;
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
      final dimensions = (frame.width, frame.height);
      if (_motionFrameSize != dimensions) {
        _motion.reset();
        _motionFrameSize = dimensions;
      }
      final counts = <String, int>{};
      for (final reading in readings) {
        final key = normalizePlate(reading.plate);
        counts[key] = (counts[key] ?? 0) + 1;
      }
      final movements = <String, PlateMotion>{};
      final staleGeometry =
          _videoClock.elapsed - frameReceiptAt > const Duration(seconds: 2);
      if (staleGeometry) _motion.reset();
      final now = DateTime.now().toUtc();
      _vehicleCandidates.removeWhere(
        (_, evidence) =>
            now.difference(evidence.capturedAt) > const Duration(seconds: 15),
      );
      for (final reading in readings) {
        final key = normalizePlate(reading.plate);
        if (staleGeometry ||
            counts[key] != 1 ||
            !reading.confidence.isFinite ||
            reading.confidence < .8) {
          _motion.discard(key);
          movements[key] = const PlateMotion();
        } else {
          movements[key] = _motion.update(key, reading.box, frameReceiptAt);
        }
        if (_vehicleVerifier != null &&
            _settings.registeredPlates.containsKey(key)) {
          final evidence = staleGeometry || counts[key] != 1
              ? null
              : reading.vehicle;
          _vehicleResults[key] = _vehicleVerifier!.assess(key, evidence, now);
        }
      }
      _motionStatus = movements.isEmpty
          ? 'Richtung unbekannt'
          : movements.values.first.label;
      for (final plate in result) {
        if (_vehicleVerifier != null &&
            _settings.registeredPlates.containsKey(plate.plate)) {
          final matches = readings
              .where((r) => normalizePlate(r.plate) == plate.plate)
              .toList();
          if (!staleGeometry &&
              matches.length == 1 &&
              matches.single.vehicle?.usable == true &&
              _vehicleVerifier!.profiles[plate.plate]?.automatic != true) {
            _vehicleCandidates[plate.plate] = matches.single.vehicle!;
            _candidateProofs[plate.plate] = plate;
          }
        }
        // Coalesce presence refreshes; never replay an outage as a queue of arrivals.
        _pendingEvents.removeWhere((event) => event.plate.plate == plate.plate);
        // A network outage must not create an unbounded event queue.
        if (_pendingEvents.length >= 100) {
          _pendingEvents.removeAt(0);
          _droppedEvents++;
        }
        _pendingEvents.add(
          PendingPlateEvent.fromPlate(
            ConfirmedPlate(
              plate: plate.plate,
              confidence: plate.confidence,
              observations: plate.observations,
              newEvent: plate.newEvent,
              motion: movements[plate.plate] ?? const PlateMotion(),
              vehicle: _settings.supportsVehicleVerification
                  ? _vehicleResults[plate.plate] ??
                        const VehicleAssessment('unknown')
                  : null,
            ),
          ),
        );
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
      unawaited(_stopLiveImage());
      setState(() => _cameraStatus = 'Pausiert – App im Vordergrund öffnen');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _configurationTimer?.cancel();
    _hideControlsTimer?.cancel();
    _foreground = false;
    _streaming = false;
    unawaited(_stopLiveImage());
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
                    color: const Color(0xED151E29),
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.videocam_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Live-Kamera',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(_cameraStatus),
                          Text(_streamStatus),
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
                          if (_lastPlate != null) ...[
                            const SizedBox(height: 16),
                            const Text(
                              'ZULETZT BESTÄTIGT',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.5,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF0F4F8),
                                borderRadius: BorderRadius.circular(8),
                                border: const Border(
                                  left: BorderSide(
                                    color: Color(0xFF2455B2),
                                    width: 10,
                                  ),
                                ),
                              ),
                              child: Text(
                                _lastPlate!,
                                style: const TextStyle(
                                  color: Color(0xFF0B1118),
                                  fontSize: 26,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                          ],
                          Text(_motionStatus),
                          if (_lastPlate != null &&
                              _vehicleResults[_lastPlate] != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Fahrzeug: ${_vehicleResults[_lastPlate]!.status}',
                            ),
                          ],
                          for (final plate in _vehicleCandidates.keys)
                            TextButton.icon(
                              onPressed: _reviewingVehicle
                                  ? null
                                  : () => _reviewVehicle(plate),
                              icon: const Icon(Icons.directions_car_outlined),
                              label: Text('$plate · Fahrzeug bestätigen'),
                            ),
                          if (_rawReading != null)
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text(
                                'Diagnose',
                                style: TextStyle(fontSize: 13),
                              ),
                              children: [
                                Text(
                                  'OCR-Rohwert (nicht bestätigt): $_rawReading',
                                ),
                              ],
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
                          onPressed: _settings.isPaired && controller != null
                              ? _toggleLiveImage
                              : null,
                          icon: Icon(
                            _streaming ? Icons.videocam_off : Icons.videocam,
                          ),
                          label: Text(
                            _streaming
                                ? 'HA-Livebild stoppen'
                                : 'HA-Livebild starten',
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
