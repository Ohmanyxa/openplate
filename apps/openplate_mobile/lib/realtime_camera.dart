import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'openplate_api.dart';
import 'settings.dart';
import 'video_frame.dart';

class _Viewer {
  _Viewer(this.connection);
  final RTCPeerConnection connection;
  bool answerSent = false;
  int sentCandidates = 0;
  final pendingCandidates = <Map<String, dynamic>>[];
}

/// One native capture source for preview, H.264 senders and local inference.
/// Signaling uses paired AES-GCM; WebRTC media uses DTLS-SRTP.
class RealtimeCamera {
  RealtimeCamera(
    this.settings, {
    required this.onStatus,
    RTCVideoRenderer? renderer,
    OpenPlateApi? api,
    this.capture,
    this.connect,
    this.videoCapabilities,
  }) : renderer = renderer ?? RTCVideoRenderer(),
       _providedApi = api;
  final OpenPlateApi? _providedApi;
  final Future<MediaStream> Function(Map<String, dynamic>)? capture;
  final Future<RTCPeerConnection> Function()? connect;
  final Future<RTCRtpCapabilities> Function()? videoCapabilities;
  final OpenPlateSettings settings;
  final void Function(String) onStatus;
  final RTCVideoRenderer renderer;
  final _client = http.Client();
  late final _api = _providedApi ?? OpenPlateApi(settings, client: _client);
  static const _channel = MethodChannel('openplate/local_recognition');
  MediaStream? _stream;
  final _viewers = <String, _Viewer>{};
  final _outgoing = <Map<String, dynamic>>[];
  int _ack = 0;
  bool _disposed = false;
  bool _rendererInitialized = false;
  bool get ready => !_disposed && _stream != null;

  Future<void> start() async {
    try {
      await renderer.initialize();
      _rendererInitialized = true;
      if (_disposed) {
        await renderer.dispose();
        return;
      }
      final live = settings.liveCamera;
      final stream = await (capture ?? navigator.mediaDevices.getUserMedia)({
        'audio': false,
        'video': {
          'facingMode': 'environment',
          'width': live.width,
          'height': live.height,
          'frameRate': live.fps,
        },
      });
      if (_disposed) {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
        return;
      }
      _stream = stream;
      renderer.srcObject = stream;
      final track = stream.getVideoTracks().single;
      await _channel.invokeMethod<void>('attachRealtimeTrack', {
        'trackId': track.id,
      });
      onStatus(
        live.enabled
            ? 'WebRTC bereit · Ziel ${live.fps} FPS · ${live.resolution}'
            : 'HA-Livebild ausgeschaltet · lokale Kamera aktiv',
      );
      unawaited(_signalLoop());
    } on Object {
      await dispose();
      rethrow;
    }
  }

  Future<VideoFrame?> readFrame() async {
    if (!ready) return null;
    final frame = await _channel.invokeMapMethod<String, dynamic>(
      'readRealtimeFrame',
    );
    if (frame == null) return null;
    return VideoFrame.bgra(
      width: frame['width'] as int,
      height: frame['height'] as int,
      bytes: frame['bytes'] as Uint8List,
      bytesPerRow: frame['bytesPerRow'] as int,
    );
  }

  void _enqueue(String sessionId, String type, Map<String, dynamic> data) {
    if (_disposed) return;
    if (_outgoing.length >= 192) {
      throw StateError('WebRTC-Signalisierung überlastet');
    }
    _outgoing.add({
      'id': const Uuid().v4(),
      'session_id': sessionId,
      'type': type,
      ...data,
    });
  }

  Future<void> _signalLoop() async {
    while (!_disposed) {
      final batch = _outgoing.take(32).toList();
      try {
        final reply = await _api.pollCameraSignaling(
          ack: _ack,
          ready: ready && settings.liveCamera.enabled,
          messages: batch,
        );
        if (_disposed) return;
        for (final message in batch) {
          _outgoing.remove(message);
        }
        final messages = reply['messages'];
        if (reply['accepted'] != true ||
            messages is! List ||
            messages.length > 64) {
          throw const FormatException('Ungültige WebRTC-Signalisierung');
        }
        for (final value in messages) {
          final message = Map<String, dynamic>.from(value as Map);
          final sequence = message['sequence'] as int;
          if (sequence <= _ack) continue;
          await _handle(message);
          _ack = sequence;
          if (_disposed) return;
        }
      } on CameraSessionChanged {
        _ack = 0;
        _outgoing.clear();
        await _closeAll();
        if (!_disposed) {
          onStatus('WebRTC-Verbindung wird nach HA-Neustart erneuert');
        }
      } on Object {
        if (_disposed) return;
        onStatus('WebRTC-Verbindung unterbrochen · neuer Versuch');
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }

  Future<void> _handle(Map<String, dynamic> message) async {
    final sessionId = message['session_id'] as String;
    try {
      switch (message['type']) {
        case 'offer':
          if (!settings.liveCamera.enabled || _viewers.length >= 2) {
            throw StateError('Livebild ausgeschaltet oder zu viele Betrachter');
          }
          await _offer(sessionId, message['sdp'] as String);
        case 'candidate':
          final candidate = Map<String, dynamic>.from(
            message['candidate'] as Map,
          );
          if ((candidate['candidate'] as String?)?.isEmpty ?? true) return;
          await _viewers[sessionId]?.connection.addCandidate(
            RTCIceCandidate(
              candidate['candidate'] as String?,
              candidate['sdpMid'] as String?,
              candidate['sdpMLineIndex'] as int?,
            ),
          );
        case 'close':
          await _close(sessionId);
        default:
          throw const FormatException('Unbekannte WebRTC-Nachricht');
      }
    } on Object {
      await _close(sessionId);
      _enqueue(sessionId, 'error', {
        'error': 'Videoverbindung konnte nicht aufgebaut werden',
      });
      onStatus('WebRTC-Aufbau fehlgeschlagen · Liveansicht erneut öffnen');
    }
  }

  Future<void> _offer(String sessionId, String sdp) async {
    await _close(sessionId);
    final stream = _stream;
    if (_disposed || stream == null) return;
    final connection =
        await (connect?.call() ??
            createPeerConnection({
              'iceServers': <Map<String, dynamic>>[],
              'sdpSemantics': 'unified-plan',
            }));
    if (_disposed || !identical(stream, _stream)) {
      await connection.close();
      await connection.dispose();
      return;
    }
    final viewer = _Viewer(connection);
    _viewers[sessionId] = viewer;
    connection.onIceCandidate = (candidate) {
      if (_disposed ||
          !identical(_viewers[sessionId], viewer) ||
          candidate.candidate == null ||
          candidate.candidate!.isEmpty) {
        return;
      }
      if (viewer.sentCandidates >= 64) return;
      viewer.sentCandidates++;
      final data = <String, dynamic>{'candidate': candidate.toMap()};
      if (viewer.answerSent) {
        _enqueue(sessionId, 'candidate', data);
      } else if (viewer.pendingCandidates.length < 64) {
        viewer.pendingCandidates.add(data);
      }
    };
    connection.onConnectionState = (state) {
      if (_disposed || !identical(_viewers[sessionId], viewer)) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        onStatus(
          'WebRTC verbunden · H.264 · Ziel ${settings.liveCamera.fps} FPS',
        );
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(_close(sessionId));
        _enqueue(sessionId, 'error', {
          'error': 'ICE-Verbindung fehlgeschlagen',
        });
        onStatus(
          'WebRTC nicht erreichbar · WLAN und Netzwerkverbindung prüfen',
        );
      }
    };
    await connection.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final sender = await connection.addTrack(
      stream.getVideoTracks().single,
      stream,
    );
    final capabilities =
        await (videoCapabilities?.call() ?? getRtpSenderCapabilities('video'));
    final h264 = (capabilities.codecs ?? [])
        .where((codec) => codec.mimeType.toLowerCase() == 'video/h264')
        .toList();
    if (h264.isEmpty) throw StateError('H.264 nicht verfügbar');
    for (final transceiver in await connection.getTransceivers()) {
      if (transceiver.sender.track?.kind == 'video') {
        await transceiver.setCodecPreferences(h264);
        await transceiver.setDirection(TransceiverDirection.SendOnly);
      }
    }
    final answer = await connection.createAnswer();
    await connection.setLocalDescription(answer);
    final parameters = sender.parameters;
    if (parameters.encodings?.isEmpty ?? true) {
      parameters.encodings = [RTCRtpEncoding()];
    }
    for (final encoding in parameters.encodings ?? <RTCRtpEncoding>[]) {
      encoding.maxFramerate = settings.liveCamera.fps;
      encoding.maxBitrate = settings.liveCamera.resolution == '720p'
          ? 2000000
          : 1000000;
    }
    parameters.degradationPreference =
        RTCDegradationPreference.MAINTAIN_FRAMERATE;
    if (!await sender.setParameters(parameters)) {
      throw StateError('Video-Sendeparameter wurden abgelehnt');
    }
    _enqueue(sessionId, 'answer', {'sdp': answer.sdp});
    viewer.answerSent = true;
    for (final candidate in viewer.pendingCandidates) {
      _enqueue(sessionId, 'candidate', candidate);
    }
    viewer.pendingCandidates.clear();
  }

  Future<void> _close(String sessionId) async {
    final viewer = _viewers.remove(sessionId);
    _outgoing.removeWhere((m) => m['session_id'] == sessionId);
    try {
      await viewer?.connection.close();
    } finally {
      await viewer?.connection.dispose();
    }
  }

  Future<void> _closeAll() async {
    await Future.wait(_viewers.keys.toList().map(_close));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _client.close();
    try {
      await _closeAll();
    } finally {
      await _releaseCapture();
    }
  }

  Future<void> _releaseCapture() async {
    try {
      await _channel.invokeMethod<void>('detachRealtimeTrack');
    } finally {
      await _releaseStream();
    }
  }

  Future<void> _releaseStream() async {
    final stream = _stream;
    _stream = null;
    if (_rendererInitialized) renderer.srcObject = null;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        await track.stop();
      }
      await stream.dispose();
    }
    if (_rendererInitialized) await renderer.dispose();
  }
}
