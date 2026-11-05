import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:openplate_mobile/openplate_api.dart';
import 'package:openplate_mobile/pairing.dart';
import 'package:openplate_mobile/realtime_camera.dart';
import 'package:openplate_mobile/settings.dart';

const settings = OpenPlateSettings(
  recognitionUrl: '',
  homeAssistantWebhookUrl: 'http://ha.local/api/webhook/test',
  deviceId: 'phone',
  captureIntervalSeconds: 1,
  apiKey: '',
  webhookSecret: 's123456789012345678901234567890123',
  supportsWebRTC: true,
  liveCamera: LiveCameraSettings(enabled: true),
);

class TestTrack implements MediaStreamTrack {
  int stops = 0;
  @override
  String get id => 'video-track';
  @override
  String get kind => 'video';
  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestStream implements MediaStream {
  final track = TestTrack();
  int disposals = 0;
  @override
  List<MediaStreamTrack> getTracks() => [track];
  @override
  List<MediaStreamTrack> getVideoTracks() => [track];
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestRenderer extends RTCVideoRenderer {
  MediaStream? stream;
  bool released = false;
  @override
  Future<void> initialize() async {}
  @override
  set srcObject(MediaStream? value) {
    stream = value;
  }

  @override
  Future<void> dispose() async {
    released = true;
    await super.dispose();
  }
}

class TestSender implements RTCRtpSender {
  TestSender(this.track);
  @override
  final MediaStreamTrack track;
  @override
  final parameters = RTCRtpParameters(encodings: [RTCRtpEncoding()]);
  @override
  Future<bool> setParameters(RTCRtpParameters parameters) async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestTransceiver implements RTCRtpTransceiver {
  TestTransceiver(this.sender);
  @override
  final TestSender sender;
  List<RTCRtpCodecCapability>? codecs;
  TransceiverDirection? direction;
  @override
  Future<void> setCodecPreferences(List<RTCRtpCodecCapability> codecs) async {
    this.codecs = codecs;
  }

  @override
  Future<void> setDirection(TransceiverDirection direction) async {
    this.direction = direction;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestPeer extends RTCPeerConnection {
  TestPeer(TestTrack track) : sender = TestSender(track) {
    transceiver = TestTransceiver(sender);
  }
  final TestSender sender;
  late final TestTransceiver transceiver;
  int closes = 0;
  RTCSessionDescription? remote;
  final candidates = <RTCIceCandidate>[];
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    remote = description;
  }

  @override
  Future<RTCRtpSender> addTrack(
    MediaStreamTrack track, [
    MediaStream? stream,
  ]) async => sender;
  @override
  Future<List<RTCRtpTransceiver>> getTransceivers() async => [transceiver];
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('h264-answer', 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {
    onIceCandidate?.call(RTCIceCandidate('local-candidate', '0', 0));
  }

  @override
  Future<void> addCandidate(RTCIceCandidate candidate) async {
    candidates.add(candidate);
  }

  @override
  Future<void> close() async {
    closes++;
  }

  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestApi extends OpenPlateApi {
  TestApi() : super(settings);
  final polls =
      <({int ack, bool ready, List<Map<String, dynamic>> messages})>[];
  final pending = <Completer<Map<String, dynamic>>>[];
  @override
  Future<Map<String, dynamic>> pollCameraSignaling({
    required int ack,
    required bool ready,
    required List<Map<String, dynamic>> messages,
  }) {
    polls.add((ack: ack, ready: ready, messages: List.of(messages)));
    final reply = Completer<Map<String, dynamic>>();
    pending.add(reply);
    return reply.future;
  }

  void reply(List<Map<String, dynamic>> messages) {
    pending.firstWhere((p) => !p.isCompleted).complete({
      'accepted': true,
      'messages': messages,
    });
  }
}

Future<void> settle() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final calls = <String>[];
  const channel = MethodChannel('openplate/local_recognition');
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'one 24 FPS capture supplies H264 sender and native inference; viewer close releases peer',
    () async {
      final stream = TestStream();
      final renderer = TestRenderer();
      final api = TestApi();
      final peer = TestPeer(stream.track);
      Map<String, dynamic>? requested;
      final camera = RealtimeCamera(
        settings,
        onStatus: (_) {},
        renderer: renderer,
        api: api,
        capture: (constraints) async {
          requested = constraints;
          return stream;
        },
        connect: () async => peer,
        videoCapabilities: () async => RTCRtpCapabilities(
          codecs: [
            RTCRtpCodecCapability(clockRate: 90000, mimeType: 'video/VP8'),
            RTCRtpCodecCapability(clockRate: 90000, mimeType: 'video/H264'),
          ],
        ),
      );
      await camera.start();
      expect(requested!['audio'], isFalse);
      expect(requested!['video']['frameRate'], 24);
      expect(renderer.stream, same(stream));
      expect(calls, contains('attachRealtimeTrack'));
      api.reply([
        {
          'sequence': 1,
          'session_id': 'viewer',
          'type': 'offer',
          'sdp': 'offer',
        },
      ]);
      await settle();
      expect(peer.remote!.sdp, 'offer');
      expect(peer.transceiver.codecs!.single.mimeType, 'video/H264');
      expect(peer.transceiver.direction, TransceiverDirection.SendOnly);
      expect(peer.sender.parameters.encodings!.single.maxFramerate, 24);
      expect(api.polls.last.messages.map((m) => m['type']), [
        'answer',
        'candidate',
      ]);
      expect(api.polls.last.ack, 1);
      api.reply([
        {
          'sequence': 2,
          'session_id': 'viewer',
          'type': 'candidate',
          'candidate': {
            'candidate': 'remote-candidate',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          },
        },
        {'sequence': 3, 'session_id': 'viewer', 'type': 'close'},
      ]);
      await settle();
      expect(peer.candidates.single.candidate, 'remote-candidate');
      expect(peer.closes, 1);
      await camera.dispose();
      api.reply([]);
      await settle();
      expect(camera.ready, isFalse);
      expect(stream.track.stops, 1);
      expect(stream.disposals, 1);
      expect(renderer.released, isTrue);
      expect(calls, contains('detachRealtimeTrack'));
    },
  );

  test('HA session restart resets cursor and closes previous viewer', () async {
    final stream = TestStream();
    final api = TestApi();
    final peer = TestPeer(stream.track);
    final camera = RealtimeCamera(
      settings,
      onStatus: (_) {},
      renderer: TestRenderer(),
      api: api,
      capture: (_) async => stream,
      connect: () async => peer,
      videoCapabilities: () async => RTCRtpCapabilities(
        codecs: [
          RTCRtpCodecCapability(clockRate: 90000, mimeType: 'video/H264'),
        ],
      ),
    );
    await camera.start();
    api.reply([
      {'sequence': 7, 'session_id': 'viewer', 'type': 'offer', 'sdp': 'offer'},
    ]);
    await settle();
    api.pending
        .firstWhere((p) => !p.isCompleted)
        .completeError(const CameraSessionChanged());
    await settle();
    expect(peer.closes, 1);
    expect(api.polls.last.ack, 0);
    expect(api.polls.last.messages, isEmpty);
    await camera.dispose();
    api.reply([]);
    await settle();
  });
}
