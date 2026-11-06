import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'openplate_api.dart';
import 'camera_controls.dart';
import 'settings.dart';
import 'video_frame.dart';
import 'realtime_camera.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCVideoView, RTCVideoViewObjectFit;
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
  RealtimeCamera? _realtime;
  Timer? _realtimeTimer;
  bool _readingRealtimeFrame = false;
  bool _haConfigurationVerified = false;
  bool? _haReachable;
  bool get _cameraReady =>
      (_realtime?.ready ?? false) ||
      (_controller?.value.isInitialized ?? false);

  Future<void> _onRealtimeFrame() async {
    final camera = _realtime;
    if (!mounted ||
        !_foreground ||
        camera == null ||
        !camera.ready ||
        _readingRealtimeFrame) {
      return;
    }
    final now = _videoClock.elapsed;
    final recognize =
        _recognizing &&
        !_busy &&
        (_lastFrame == null ||
            now - _lastFrame! >=
                Duration(seconds: _settings.captureIntervalSeconds));
    final thumbnail =
        _haConfigurationVerified &&
        _streaming &&
        !_sendingFrame &&
        !_stoppingStream &&
        (_lastStreamFrame == null ||
            now - _lastStreamFrame! >= const Duration(seconds: 5));
    if (!recognize && !thumbnail) return;
    _readingRealtimeFrame = true;
    final generation = _generation;
    try {
      final frame = await camera.readFrame();
      if (!mounted ||
          !_foreground ||
          generation != _generation ||
          frame == null) {
        return;
      }
      if (recognize) {
        _lastFrame = now;
        unawaited(_processFrame(frame));
      }
      if (thumbnail) {
        _lastStreamFrame = now;
        unawaited(_sendLiveFrame(frame, generation));
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() => _cameraStatus = 'Kamerabild noch nicht verfügbar');
      }
    } finally {
      _readingRealtimeFrame = false;
    }
  }

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
  late bool _recognitionWanted = widget.settings.isPaired;
  Timer? _recognitionRetryTimer;
  bool _modelsReady = false;
  bool _sendingEvents = false;
  bool _streaming = false;
  bool _legacyLiveConnected = false;
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
            'orientation': _realtime != null
                ? 'landscapeLeft'
                : (_controller?.value.deviceOrientation.name ?? 'portraitUp'),
          });
      if (!mounted ||
          !_streaming ||
          !_foreground ||
          generation != _generation ||
          jpeg == null) {
        return;
      }
      await api.sendCameraFrame(jpeg, capturedAt);
      if (mounted && _streaming && _realtime == null) {
        setState(() {
          _legacyLiveConnected = true;
          _streamStatus = 'Livebild verschlüsselt an Home Assistant';
        });
      }
    } on Object {
      if (mounted && _streaming && _realtime == null) {
        setState(() {
          _legacyLiveConnected = false;
          _streamStatus =
              'Livebild unterbrochen · Verbindung wird erneut versucht';
        });
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
      _legacyLiveConnected = false;
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
    _haConfigurationVerified = false;
    _legacyLiveConnected = false;
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
      final previousRealtime = _realtime;
      _realtime = null;
      _realtimeTimer?.cancel();
      _controller = null;
      if (mounted) setState(() {});
      try {
        try {
          if (previous?.value.isStreamingImages ?? false) {
            await previous!.stopImageStream();
          }
        } finally {
          await previous?.dispose();
          await previousRealtime?.dispose();
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
        if (Platform.isIOS && _settings.supportsWebRTC) {
          final realtime = RealtimeCamera(
            _settings,
            onStatus: (status) {
              if (mounted && generation == _generation) {
                setState(() => _streamStatus = status);
              }
            },
          );
          await realtime.start();
          if (!mounted || generation != _generation || !_foreground) {
            await realtime.dispose();
            return;
          }
          setState(() {
            _realtime = realtime;
            _streaming = _settings.liveCamera.enabled;
            _cameraStatus = 'Kamera aktiv · gemeinsame WebRTC-Aufnahme';
          });
          unawaited(_ensureRecognitionStarted());
          _realtimeTimer = Timer.periodic(
            const Duration(milliseconds: 100),
            (_) => unawaited(_onRealtimeFrame()),
          );
          return;
        }
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
        unawaited(_ensureRecognitionStarted());
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
      final cameraChanged =
          updated.supportsWebRTC != _settings.supportsWebRTC ||
          updated.liveCamera != _settings.liveCamera;
      final changed =
          cameraChanged ||
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
        if (cameraChanged) _queueCamera(_foreground);
      }
      _haConfigurationVerified = true;
      _haReachable = true;
      await _configureVehicles();
      setState(() => _haStatus = 'Home Assistant verbunden');
    } on Object {
      _haReachable = false;
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

  Future<void> _ensureRecognitionStarted() async {
    if (!mounted ||
        !_recognitionWanted ||
        _recognizing ||
        !_foreground ||
        !_settings.isComplete ||
        !_cameraReady ||
        _startingRecognition) {
      return;
    }
    _recognitionRetryTimer?.cancel();
    if (!_modelsReady) {
      setState(() {
        _startingRecognition = true;
        _recognitionStatus =
            'Lokale Modelle werden automatisch geladen. Erster Start benötigt Internet (ca. 11 MB).';
      });
      try {
        await _local.initialize();
        if (!mounted) return;
        await _configureVehicles();
        _modelsReady = true;
      } on Object catch (error) {
        if (mounted) {
          setState(() {
            _startingRecognition = false;
            final reason = error is PlatformException
                ? error.message ??
                      'Lokale Modelle konnten nicht gestartet werden'
                : 'Lokale Erkennung nicht verfügbar. iOS-App verwenden und Modell-Download prüfen.';
            _recognitionStatus =
                '$reason · Automatischer neuer Versuch in 30 Sekunden.';
          });
          if (_recognitionWanted && _foreground) {
            _recognitionRetryTimer = Timer(
              const Duration(seconds: 30),
              () => unawaited(_ensureRecognitionStarted()),
            );
          }
        }
        return;
      }
      if (!mounted) return;
      _startingRecognition = false;
    }
    if (!_foreground || !_cameraReady || !_recognitionWanted) {
      setState(
        () => _recognitionStatus = _recognitionWanted
            ? 'Modelle bereit · automatischer Start, sobald die Kamera verfügbar ist'
            : 'Erkennung ausgeschaltet',
      );
      return;
    }
    setState(() {
      _recognizing = true;
      _recognitionStatus = 'Lokale Erkennung aktiv · ONNX Runtime / iPhone CPU';
    });
    _resetFrameAdmission();
  }

  Future<void> _processFrame(VideoFrame frame) async {
    if (_busy || !_recognizing || !_foreground || !_cameraReady) {
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
      setState(
        () => _cameraStatus =
            'iOS pausiert die Kamera · automatischer Neustart beim Öffnen',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _configurationTimer?.cancel();
    _recognitionRetryTimer?.cancel();
    _realtimeTimer?.cancel();
    _hideControlsTimer?.cancel();
    _foreground = false;
    _recognitionWanted = false;
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
              if (!_blackMode && _realtime?.ready == true)
                RTCVideoView(
                  _realtime!.renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                ),
              if (_blackMode)
                const ColoredBox(
                  key: Key('all-black-screen'),
                  color: Colors.black,
                ),
              if (!_blackMode || _controlsVisible)
                SafeArea(child: _buildControls()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final paired = _settings.isPaired;
    final retrying = _recognitionRetryTimer?.isActive ?? false;
    final recognition = !paired
        ? 'Kopplung erforderlich'
        : !_foreground
        ? 'Pausiert'
        : _recognizing
        ? 'Läuft automatisch'
        : _startingRecognition
        ? 'Modelle werden geladen'
        : retrying
        ? 'Automatischer neuer Versuch'
        : 'Startet automatisch';
    final liveEnabled = _settings.supportsWebRTC
        ? _settings.liveCamera.enabled
        : _streaming;
    final liveConnected = _realtime?.isConnected ?? _legacyLiveConnected;
    final live = !paired
        ? 'Nicht gekoppelt'
        : !_foreground
        ? 'Pausiert'
        : !liveEnabled
        ? 'In HA ausgeschaltet'
        : liveConnected
        ? 'Live verbunden'
        : _cameraReady && _haReachable == true
        ? 'Bereit für Liveansicht'
        : 'Wird verbunden';
    final verdict = _vehicleResults[_lastPlate]?.status;
    final vehicle = switch (verdict) {
      'confirmed' => 'Bestätigt',
      'match' => 'Passt zum Profil',
      'mismatch' => 'Abweichung erkannt',
      'enrollment_required' => 'Einlernen erforderlich',
      'unknown' => 'Noch nicht geprüft',
      _ => null,
    };
    return CameraControls(
      paired: paired,
      blackMode: _blackMode,
      statusLabel: !_foreground
          ? 'Pausiert'
          : _cameraError
          ? 'Fehler'
          : _cameraReady
          ? 'Aktiv'
          : 'Startet',
      statusTone: _cameraError
          ? CameraStatusTone.error
          : _cameraReady && _foreground
          ? CameraStatusTone.active
          : CameraStatusTone.pending,
      statuses: [
        CameraStatusItem(
          Icons.center_focus_strong_outlined,
          'Erkennung',
          recognition,
          !_foreground
              ? CameraStatusTone.muted
              : _recognizing
              ? CameraStatusTone.active
              : paired
              ? CameraStatusTone.pending
              : CameraStatusTone.muted,
        ),
        CameraStatusItem(
          Icons.home_outlined,
          'Home Assistant',
          !paired
              ? 'Nicht gekoppelt'
              : _haReachable == true
              ? 'Verbunden'
              : _haReachable == false
              ? 'Nicht erreichbar'
              : 'Wird verbunden',
          _haReachable == true
              ? CameraStatusTone.active
              : paired
              ? CameraStatusTone.pending
              : CameraStatusTone.muted,
        ),
        CameraStatusItem(
          Icons.videocam_outlined,
          'Livebild',
          live,
          !_foreground
              ? CameraStatusTone.muted
              : liveConnected
              ? CameraStatusTone.active
              : liveEnabled
              ? CameraStatusTone.pending
              : CameraStatusTone.muted,
        ),
      ],
      notice: _cameraError ? _cameraStatus : null,
      lastPlate: _lastPlate,
      motionStatus: _motionStatus,
      vehicleLabel: vehicle,
      vehicleActions: [
        for (final plate in _vehicleCandidates.keys)
          TextButton.icon(
            onPressed: _reviewingVehicle ? null : () => _reviewVehicle(plate),
            icon: const Icon(Icons.directions_car_outlined),
            label: Text('$plate · Fahrzeug bestätigen'),
          ),
      ],
      details: {
        'Kamera': _cameraStatus,
        'Erkennung': _recognitionStatus,
        'Verbindung': _haStatus,
        'Livebild': _streamStatus,
        if (_settings.supportsWebRTC)
          'Bildqualität':
              '${_settings.liveCamera.resolution} · Ziel ${_settings.liveCamera.fps} FPS',
        'OCR-Rohwert (nicht bestätigt)': ?_rawReading,
      },
      onBack: () => Navigator.of(context).pop(),
      onRetry: _cameraError ? () => _queueCamera(_foreground) : null,
      onToggleBlackMode: _toggleBlackMode,
      onToggleLegacyLive: !_settings.supportsWebRTC && paired && _cameraReady
          ? _toggleLiveImage
          : null,
      legacyStreaming: _streaming,
    );
  }
}
