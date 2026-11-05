import Flutter
import UIKit
import WebRTC
import XCTest
import onnxruntime_objc
@testable import Runner

class RunnerTests: XCTestCase {

  func testRealtimeFramesUseLatestBufferAndHonorRotation() throws {
    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 2,
      kCVPixelFormatType_32BGRA, [kCVPixelBufferCGImageCompatibilityKey: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixelBuffer), kCVReturnSuccess)
    let buffer = try XCTUnwrap(pixelBuffer)
    CVPixelBufferLockBaseAddress(buffer, [])
    let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
    for row in 0..<2 {
      for column in 0..<4 {
        let index = row * CVPixelBufferGetBytesPerRow(buffer) + column * 4
        pointer[index] = 0; pointer[index + 1] = 0; pointer[index + 2] = 255; pointer[index + 3] = 255
      }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    let frames = OpenPlateRealtimeFrames()
    XCTAssertNil(frames.snapshot())
    frames.renderFrame(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
      rotation: ._90, timeStampNs: 1))
    let portrait = try XCTUnwrap(frames.snapshot())
    XCTAssertEqual(portrait["width"] as? Int, 2)
    XCTAssertEqual(portrait["height"] as? Int, 4)
    let bytes = try XCTUnwrap(portrait["bytes"] as? FlutterStandardTypedData).data
    XCTAssertEqual(bytes.count, 32)
    XCTAssertLessThan(bytes[0], 5)
    XCTAssertGreaterThan(bytes[2], 250)
    frames.renderFrame(RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
      rotation: ._0, timeStampNs: 2))
    XCTAssertEqual(frames.snapshot()?["width"] as? Int, 4)
    frames.clear()
    XCTAssertNil(frames.snapshot())
  }


  func testRealtimeI420AndAdaptedBuffersRemainUsableForRecognition() throws {
    let yuv = RTCMutableI420Buffer(width: 4, height: 2)
    yuv.mutableDataY.initialize(repeating: 81, count: Int(yuv.strideY * yuv.height))
    yuv.mutableDataU.initialize(repeating: 90, count: Int(yuv.strideU * yuv.chromaHeight))
    yuv.mutableDataV.initialize(repeating: 240, count: Int(yuv.strideV * yuv.chromaHeight))
    let frames = OpenPlateRealtimeFrames()
    frames.renderFrame(RTCVideoFrame(buffer: yuv, rotation: ._0, timeStampNs: 1))
    let snapshot = try XCTUnwrap(frames.snapshot())
    XCTAssertEqual(snapshot["width"] as? Int, 4)
    XCTAssertEqual(snapshot["height"] as? Int, 2)
    let bytes = try XCTUnwrap(snapshot["bytes"] as? FlutterStandardTypedData).data
    XCTAssertLessThan(bytes[0], 8)
    XCTAssertLessThan(bytes[1], 8)
    XCTAssertGreaterThan(bytes[2], 245)

    var pixelBuffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 8, 4,
      kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
    let adapted = RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixelBuffer),
      adaptedWidth: 2, adaptedHeight: 2, cropWidth: 4, cropHeight: 4, cropX: 2, cropY: 0)
    frames.renderFrame(RTCVideoFrame(buffer: adapted, rotation: ._90, timeStampNs: 2))
    XCTAssertEqual(frames.snapshot()?["width"] as? Int, 2)
    XCTAssertEqual(frames.snapshot()?["height"] as? Int, 2)
    frames.clear()
  }

  func testVehicleAssociationAndSSDDecoding() throws {
    let car = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
    let plate = CGRect(x: 0.3, y: 0.5, width: 0.2, height: 0.05)
    XCTAssertTrue(NativeVehicleModels.containsPlate(car, plate))
    XCTAssertFalse(NativeVehicleModels.containsPlate(plate, plate))
    XCTAssertFalse(NativeVehicleModels.containsPlate(car,
      CGRect(x: 0.9, y: 0.5, width: 0.1, height: 0.05)))
    let locations = [Float](repeating: 0, count: 5376)
    var priors = [Float](repeating: 0, count: 10752)
    priors.replaceSubrange(0..<4, with: [0.1, 0.1, 0.8, 0.8])
    var scores = [Float](repeating: 0, count: 2688)
    scores[0] = 0.95
    let boxes = try NativeVehicleModels.decodeSSD(locations: locations, scores: scores, priors: priors)
    XCTAssertEqual(boxes.count, 1)
    XCTAssertEqual(boxes[0].minX, 0.1, accuracy: 0.00001)
    XCTAssertEqual(boxes[0].width, 0.7, accuracy: 0.00001)
  }

  func testBundledVehicleModelsProduceLocalDescriptors() throws {
    let models = try NativeVehicleModels(ORTEnv(loggingLevel: .error))
    let frame = BgraVideoFrame(bytes: Data(repeating: 128, count: 128 * 128 * 4),
      width: 128, height: 128, stride: 128 * 4)
    XCTAssertLessThanOrEqual(try models.detect(frame).count, 4)
    let evidence = try models.describe(frame, box: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))
    let vector = try XCTUnwrap(evidence["embedding"] as? [Double])
    XCTAssertEqual(vector.count, 512)
    XCTAssertEqual(vector.reduce(0) { $0 + $1 * $1 }, 1, accuracy: 0.00001)
    XCTAssertNotNil(evidence["preview"] as? FlutterStandardTypedData)
  }

  func testBGRAResizeHonorsPaddingAndRGBOrder() {
    let frame = BgraVideoFrame(bytes: Data([0, 0, 255, 255, 77, 77, 77, 77,
                                          0, 255, 0, 255, 77, 77, 77, 77]),
                               width: 1, height: 2, stride: 8)
    XCTAssertEqual(frame.rgbResized(x: 0, y: 0, width: 1, height: 2,
      targetWidth: 1, targetHeight: 2), [255, 0, 0, 0, 255, 0])
    let input = frame.detectorInput()
    XCTAssertEqual(input.ratio, 192)
    XCTAssertEqual(input.padX, 96)
    XCTAssertEqual(input.padY, 0)
    XCTAssertEqual(input.data.count, 3 * 384 * 384 * 4)
  }

  func testCTCDecodesUmlautsBlanksAndRepeatedDigits() throws {
    let alphabet = LocalPlateRecognizer.latinAlphabet
    XCTAssertEqual(alphabet.count, 838)
    for text in ["MÜAB111", "BÖAB12", "SÄKAB123"] {
      var probabilities = [Float]()
      for character in text.map(String.init) {
        let index = try XCTUnwrap(alphabet.firstIndex(of: character))
        for best in [index, index, 0] {
          var row = [Float](repeating: 0, count: alphabet.count)
          row[best] = 0.99
          probabilities += row
        }
      }
      let decoded = try XCTUnwrap(LocalPlateRecognizer.decodePlate(probabilities))
      XCTAssertEqual(decoded.text, text)
      XCTAssertEqual(decoded.confidence, 0.99, accuracy: 0.00001)
      probabilities[0] = .nan
      XCTAssertThrowsError(try LocalPlateRecognizer.decodePlate(probabilities))
    }
    // Never drop an unsupported character to manufacture a matching German plate.
    var unsupported = [Float](repeating: 0, count: alphabet.count)
    unsupported[try XCTUnwrap(alphabet.firstIndex(of: "À"))] = 0.99
    XCTAssertNil(try LocalPlateRecognizer.decodePlate(unsupported))
  }

  func testLatinPreprocessingBGRNormalizationAndRightPadding() {
    let frame = BgraVideoFrame(bytes: Data([0, 0, 255, 255]), width: 1, height: 1, stride: 4)
    let input = frame.latinOCRInput(x: 0, y: 0, width: 1, height: 1)
    let floats = input.withUnsafeBytes { raw in
      (0..<(input.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
    XCTAssertEqual(floats.count, 3 * 48 * 320)
    XCTAssertEqual(floats[0], -1) // B
    XCTAssertEqual(floats[48 * 320], -1) // G
    XCTAssertEqual(floats[2 * 48 * 320], 1) // R
    XCTAssertEqual(floats[48], 0) // zero padding, not black (-1)
  }

  func testPinnedLatinModelReadsRenderedGermanUmlauts() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENPLATE_MODEL_TESTS"] == "1")
    let recognizer = LocalPlateRecognizer()
    try recognizer.loadModels(await LocalModelStore.prepare())
    for text in ["MÜ AB123", "BÖ AB123", "SÄK AB123"] {
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedSystemFont(ofSize: 110, weight: .medium),
        .foregroundColor: UIColor.black,
      ]
      // Match the tightly detected plate crop, not a wide canvas with empty margins.
      let extent = (text as NSString).size(withAttributes: attributes)
      let size = CGSize(width: ceil(extent.width) + 24, height: ceil(extent.height) + 12)
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        (text as NSString).draw(at: CGPoint(x: 12, y: 6), withAttributes: attributes)
      }
      let frame = try bgraFrame(XCTUnwrap(image.cgImage))
      let reading = try XCTUnwrap(recognizer.readPlate(frame))
      print("Synthetic Latin OCR: \(text) → \(reading.text)")
      XCTAssertEqual(reading.text, text.replacingOccurrences(of: " ", with: ""))
    }
  }

  private func bgraFrame(_ image: CGImage) throws -> BgraVideoFrame {
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return BgraVideoFrame(bytes: Data(pixels), width: image.width, height: image.height, stride: image.width * 4)
  }

  /// Explicit opt-in downloads pinned models and a public upstream smoke image.
  /// This is not a German-plate accuracy benchmark or a physical-device performance test.
  func testPinnedModelsRecognizeUpstreamImageLocally() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["OPENPLATE_MODEL_TESTS"] == "1")
    let paths = try await LocalModelStore.prepare()
    let recognizer = LocalPlateRecognizer()
    try recognizer.loadModels(paths)
    let url = URL(string: "https://raw.githubusercontent.com/ankandrew/fast-alpr/c5a94706f175590b2bc09aa86f46182d4c267fae/assets/test_image.png")!
    let (data, _) = try await URLSession.shared.data(from: url)
    let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
    var bgra = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try XCTUnwrap(CGContext(data: &bgra, width: image.width, height: image.height,
      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let frame = BgraVideoFrame(bytes: Data(bgra), width: image.width,
      height: image.height, stride: image.width * 4)
    let readings = try recognizer.recognize(frame)
    XCTAssertEqual(readings.compactMap { $0["plate"] as? String }, ["5AU5341"],
      "Native decoding must match the Python ONNX reference for this exact smoke image")
    let boxes = readings.compactMap { $0["box"] as? [Double] }
    XCTAssertEqual(boxes.count, readings.count)
    for box in boxes {
      XCTAssertEqual(box.count, 4)
      XCTAssertTrue(box.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
      XCTAssertLessThanOrEqual(box[0] + box[2], 1)
      XCTAssertLessThanOrEqual(box[1] + box[3], 1)
    }
    XCTAssertTrue(readings.allSatisfy { ($0["plate"] as? String)?.isEmpty == false })
    recognizer.configureVehiclePlates(["5AU5341"])
    let verified = try recognizer.recognize(frame)
    let vehicle = try XCTUnwrap(verified.first?["vehicle"] as? [String: Any],
      "A known plate must be associated with the full visible car in the upstream scene")
    XCTAssertEqual((vehicle["embedding"] as? [Double])?.count, 512)
    XCTAssertNotNil(vehicle["preview"] as? FlutterStandardTypedData)
  }

}
