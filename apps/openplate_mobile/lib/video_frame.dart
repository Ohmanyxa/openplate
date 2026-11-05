import 'dart:typed_data';

import 'package:camera/camera.dart';

/// Owned video buffers for device-local inference. Never encoded for transport.
class VideoFrame {
  VideoFrame(CameraImage image)
    : width = image.width,
      height = image.height,
      format = image.format.group,
      planes = image.planes.map((p) => Uint8List.fromList(p.bytes)).toList(),
      strides = image.planes.map((p) => p.bytesPerRow).toList();

  VideoFrame.bgra({
    required this.width,
    required this.height,
    required Uint8List bytes,
    required int bytesPerRow,
  }) : format = ImageFormatGroup.bgra8888,
       planes = [bytes],
       strides = [bytesPerRow];

  final int width;
  final int height;
  final ImageFormatGroup format;
  final List<Uint8List> planes;
  final List<int> strides;
}
