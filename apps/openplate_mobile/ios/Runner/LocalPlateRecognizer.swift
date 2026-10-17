import CryptoKit
import Flutter
import Foundation
import onnxruntime_objc

/// All tensors, crops and model execution stay in this process. No frame networking.
final class LocalPlateRecognizer: NSObject, FlutterPlugin {
  private let worker = DispatchQueue(label: "openplate.inference", qos: .userInitiated)
  private var environment: ORTEnv?
  private var detector: ORTSession?
  private var reader: ORTSession?

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "openplate/local_recognition", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocalPlateRecognizer(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "initialize":
      Task {
        do {
          let paths = try await LocalModelStore.prepare()
          worker.async {
            do {
              try self.loadModels(paths)
              DispatchQueue.main.async { result("ONNX Runtime · iPhone CPU") }
            } catch { self.fail(result, code: "model_initialization", error: error) }
          }
        } catch { self.fail(result, code: "model_download", error: error) }
      }
    case "recognize":
      guard let args = call.arguments as? [String: Any],
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            let width = args["width"] as? Int,
            let height = args["height"] as? Int,
            let stride = args["bytesPerRow"] as? Int,
            width > 0, height > 0, width <= 4096, height <= 4096,
            stride >= width * 4, bytes.data.count >= stride * height else {
        result(FlutterError(code: "invalid_frame", message: "Ungültiger BGRA-Video-Frame", details: nil))
        return
      }
      worker.async {
        do {
          let readings = try self.recognize(BgraVideoFrame(bytes: bytes.data, width: width, height: height, stride: stride))
          DispatchQueue.main.async { result(readings) }
        } catch { self.fail(result, code: "local_inference", error: error) }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }

  // Called only on the serial inference worker (or by isolated native tests).
  func loadModels(_ paths: [URL]) throws {
    guard detector == nil else { return }
    let env = try ORTEnv(loggingLevel: .warning)
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(2)
    let detection = try ORTSession(env: env, modelPath: paths[0].path, sessionOptions: options)
    let ocr = try ORTSession(env: env, modelPath: paths[1].path, sessionOptions: options)
    environment = env
    detector = detection
    reader = ocr
  }

  private func fail(_ result: @escaping FlutterResult, code: String, error: Error) {
    // Model/runtime errors do not contain image bytes or decoded plate text.
    DispatchQueue.main.async {
      result(FlutterError(code: code, message: error.localizedDescription, details: nil))
    }
  }

  func recognize(_ frame: BgraVideoFrame) throws -> [[String: Any]] {
    guard let detector, let reader else { throw LocalInferenceError.notReady }
    let prepared = frame.detectorInput()
    let tensor = try ORTValue(tensorData: NSMutableData(data: prepared.data), elementType: .float, shape: [1, 3, 384, 384])
    let outputs = try detector.run(withInputs: ["images": tensor], outputNames: ["output0"], runOptions: nil)
    guard let detectionOutput = outputs["output0"] else { throw LocalInferenceError.contract }
    let detectionShape = try detectionOutput.tensorTypeAndShapeInfo().shape.map { $0.intValue }
    let values = try Self.floats(detectionOutput)
    guard detectionShape.count == 2, detectionShape.last == 7, values.count % 7 == 0 else {
      throw LocalInferenceError.contract
    }
    var readings: [[String: Any]] = []
    // Bound OCR work on pathological scenes. Highest-confidence boxes first.
    let rows = stride(from: 0, to: values.count, by: 7)
      .filter { values[$0 + 6].isFinite && values[$0 + 6] >= 0.4 }
      .sorted { values[$0 + 6] > values[$1 + 6] }.prefix(8)
    for i in rows {
      let coordinates = (1...4).map { Double(values[i + $0]) }
      guard coordinates.allSatisfy({ $0.isFinite }) else { continue }
      let x1 = Int(max(0, min(Double(frame.width), (coordinates[0] - prepared.padX) / prepared.ratio)))
      let y1 = Int(max(0, min(Double(frame.height), (coordinates[1] - prepared.padY) / prepared.ratio)))
      let x2 = Int(max(0, min(Double(frame.width), (coordinates[2] - prepared.padX) / prepared.ratio)))
      let y2 = Int(max(0, min(Double(frame.height), (coordinates[3] - prepared.padY) / prepared.ratio)))
      guard x2 > x1, y2 > y1 else { continue }
      let crop = frame.rgbResized(x: x1, y: y1, width: x2 - x1, height: y2 - y1, targetWidth: 128, targetHeight: 64)
      let ocrInput = try ORTValue(tensorData: NSMutableData(data: Data(crop)), elementType: .uInt8, shape: [1, 64, 128, 3])
      let inputs = try reader.inputNames()
      guard inputs.count == 1, let inputName = inputs.first else { throw LocalInferenceError.contract }
      let ocr = try reader.run(withInputs: [inputName: ocrInput], outputNames: ["plate"], runOptions: nil)
      guard let plate = ocr["plate"] else { throw LocalInferenceError.contract }
      guard try plate.tensorTypeAndShapeInfo().shape.map({ $0.intValue }) == [1, 10, 37] else {
        throw LocalInferenceError.contract
      }
      if let decoded = try Self.decodePlate(Self.floats(plate)) {
        readings.append(["plate": decoded.text, "confidence": decoded.confidence])
      }
    }
    return readings
  }

  static func floats(_ value: ORTValue) throws -> [Float] {
    let data = try value.tensorData() as Data
    guard data.count % 4 == 0 else { throw LocalInferenceError.contract }
    return data.withUnsafeBytes { raw in
      (0..<(data.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
    }
  }

  static func decodePlate(_ probabilities: [Float]) throws -> (text: String, confidence: Double)? {
    guard probabilities.count == 370,
          probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
      throw LocalInferenceError.contract
    }
    let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_")
    var text = ""
    var confidence = 0.0
    var paddingSeen = false
    // These are ten independent classification slots, NOT CTC. Do not collapse repeats.
    for slot in 0..<10 {
      let offset = slot * 37
      let best = (0..<37).max { probabilities[offset + $0] < probabilities[offset + $1] }!
      if alphabet[best] != "_" {
        // Do not turn an uncertain internal blank into a different valid-looking plate.
        if paddingSeen { return nil }
        text.append(alphabet[best])
        confidence += Double(probabilities[offset + best])
      } else {
        paddingSeen = true
      }
    }
    return text.isEmpty ? nil : (text, confidence / Double(text.count))
  }
}

enum LocalInferenceError: LocalizedError {
  case notReady, contract, download, checksum
  var errorDescription: String? {
    switch self {
    case .notReady: return "Lokale Modelle sind noch nicht geladen."
    case .contract: return "Modell-Ein-/Ausgabe entspricht nicht dem erwarteten Format."
    case .download: return "Modell-Download fehlgeschlagen. Internetverbindung beim ersten Start prüfen."
    case .checksum: return "Modell-Prüfsumme stimmt nicht überein."
    }
  }
}

/// Exact upstream artifacts; downloaded once, hash-verified, then usable offline.
enum LocalModelStore {
  static let artifacts: [(String, String, String)] = [
    ("detector.onnx", "https://github.com/ankandrew/open-image-models/releases/download/assets/yolo-v9-t-384-license-plates-end2end.onnx", "888397b96d761c89db40bc9c305838e8652660f5e282c2cadebbe8d2951a77a8"),
    ("ocr.onnx", "https://github.com/ankandrew/cnn-ocr-lp/releases/download/arg-plates/cct_xs_v2_global.onnx", "8031afb5fdc6b4d80462c9d542f1284ebd2cfddf5dbacd62609848d7e2855f44"),
  ]

  static func prepare() async throws -> [URL] {
    let manager = FileManager.default
    var directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("OpenPlateModels-v1", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    var flags = URLResourceValues()
    flags.isExcludedFromBackup = true
    try directory.setResourceValues(flags)
    var paths: [URL] = []
    for (name, source, expected) in artifacts {
      let destination = directory.appendingPathComponent(name)
      if let cached = try? Data(contentsOf: destination), digest(cached) == expected {
        paths.append(destination)
        continue
      }
      let (temporary, response) = try await URLSession.shared.download(from: URL(string: source)!)
      defer { try? manager.removeItem(at: temporary) }
      guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme == "https" else { throw LocalInferenceError.download }
      let data = try Data(contentsOf: temporary)
      guard data.count <= 20 * 1024 * 1024, digest(data) == expected else {
        throw LocalInferenceError.checksum
      }
      try data.write(to: destination, options: .atomic)
      paths.append(destination)
    }
    return paths
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

struct BgraVideoFrame {
  let bytes: Data
  let width: Int
  let height: Int
  let stride: Int

  // OpenCV-style bilinear pixel-centre sampling, RGB output, row-stride aware.
  func rgbResized(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int,
                  targetWidth: Int, targetHeight: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: targetWidth * targetHeight * 3)
    bytes.withUnsafeBytes { raw in
      let source = raw.bindMemory(to: UInt8.self)
      for dy in 0..<targetHeight {
        let sy = max(0, min(Double(cropHeight - 1), (Double(dy) + 0.5) * Double(cropHeight) / Double(targetHeight) - 0.5))
        let y0 = Int(sy), y1 = min(y0 + 1, cropHeight - 1), fy = sy - Double(y0)
        for dx in 0..<targetWidth {
          let sx = max(0, min(Double(cropWidth - 1), (Double(dx) + 0.5) * Double(cropWidth) / Double(targetWidth) - 0.5))
          let x0 = Int(sx), x1 = min(x0 + 1, cropWidth - 1), fx = sx - Double(x0)
          for c in 0..<3 {
            let bgra = 2 - c
            let p00 = Double(source[(y + y0) * stride + (x + x0) * 4 + bgra])
            let p01 = Double(source[(y + y0) * stride + (x + x1) * 4 + bgra])
            let p10 = Double(source[(y + y1) * stride + (x + x0) * 4 + bgra])
            let p11 = Double(source[(y + y1) * stride + (x + x1) * 4 + bgra])
            output[(dy * targetWidth + dx) * 3 + c] = UInt8(max(0, min(255,
              ((p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy).rounded())))
          }
        }
      }
    }
    return output
  }

  func detectorInput() -> (data: Data, ratio: Double, padX: Double, padY: Double) {
    let ratio = min(384.0 / Double(width), 384.0 / Double(height))
    let w = max(1, Int((Double(width) * ratio).rounded(.toNearestOrEven)))
    let h = max(1, Int((Double(height) * ratio).rounded(.toNearestOrEven)))
    let padX = Double(384 - w) / 2, padY = Double(384 - h) / 2
    let left = Int((padX - 0.1).rounded()), top = Int((padY - 0.1).rounded())
    let rgb = rgbResized(x: 0, y: 0, width: width, height: height, targetWidth: w, targetHeight: h)
    var tensor = [Float](repeating: 114.0 / 255.0, count: 3 * 384 * 384)
    for y in 0..<h {
      for x in 0..<w {
        for c in 0..<3 {
          tensor[c * 384 * 384 + (y + top) * 384 + x + left] = Float(rgb[(y * w + x) * 3 + c]) / 255
        }
      }
    }
    return (tensor.withUnsafeBytes { Data($0) }, ratio, padX, padY)
  }
}
