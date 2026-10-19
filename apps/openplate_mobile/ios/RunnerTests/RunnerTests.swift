import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

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

  func testOCRSlotsKeepRepeatedCharacters() throws {
    var probabilities = [Float](repeating: 0, count: 370)
    let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
    for (i, c) in Array("BXX111____").enumerated() {
      probabilities[i * 37 + alphabet.firstIndex(of: c)!] = 0.99
    }
    let decoded = try LocalPlateRecognizer.decodePlate(probabilities)
    XCTAssertEqual(decoded?.text, "BXX111")
    XCTAssertEqual(decoded!.confidence, 0.99, accuracy: 0.00001)
    probabilities[0] = .nan
    XCTAssertThrowsError(try LocalPlateRecognizer.decodePlate(probabilities))
  }

  func testUmlautsRequireMatchingIndependentImageReading() {
    for (plain, german) in [("MUB123", "MÜB123"), ("OAB12", "ÖAB12"), ("AAB12", "ÄAB12")] {
      let result = LocalPlateRecognizer.mergeUmlautReading((plain, 0.96),
        candidates: [(german, 0.9)])
      XCTAssertEqual(result.text, german)
      XCTAssertEqual(result.confidence, 0.9)
    }
    let plain = (text: "MUB123", confidence: 0.96)
    XCTAssertEqual(LocalPlateRecognizer.mergeUmlautReading(plain,
      candidates: [("MU\u{0308} B-123", 0.9)]).text, "MÜB123")
    for candidates: [(String, Double)] in [[], [("MÜB123", 0.7)], [("MÜB124", 0.99)],
                                          [("MÜB123", .nan)], [("MÙB123", 0.99)]] {
      XCTAssertEqual(LocalPlateRecognizer.mergeUmlautReading(plain, candidates: candidates).text, plain.text)
    }
    XCTAssertEqual(LocalPlateRecognizer.mergeUmlautReading(("AUB12", 0.95),
      candidates: [("ÄUB12", 0.9), ("AÜB12", 0.9)]).text, "AUB12")
  }

  /// Synthetic rendering tests the Vision path, not real German-plate accuracy.
  func testLocalVisionReadsRenderedGermanUmlauts() throws {
    for text in ["MÜ AB123", "BÖ AB123", "SÄK AB123"] {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(size: CGSize(width: 1000, height: 180), format: format).image { _ in
        UIColor.white.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 1000, height: 180))
        (text as NSString).draw(at: CGPoint(x: 35, y: 15), withAttributes: [
          .font: UIFont.monospacedSystemFont(ofSize: 110, weight: .medium),
          .foregroundColor: UIColor.black,
        ])
      }
      let candidates = try LocalPlateRecognizer.germanTextCandidates(XCTUnwrap(image.cgImage))
      let base = text.replacingOccurrences(of: " ", with: "")
        .replacingOccurrences(of: "Ü", with: "U").replacingOccurrences(of: "Ö", with: "O")
        .replacingOccurrences(of: "Ä", with: "A")
      XCTAssertEqual(LocalPlateRecognizer.mergeUmlautReading((base, 0.99), candidates: candidates).text,
                     text.replacingOccurrences(of: " ", with: ""))
    }
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
    let readings = try recognizer.recognize(BgraVideoFrame(bytes: Data(bgra), width: image.width,
      height: image.height, stride: image.width * 4))
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
  }

}
