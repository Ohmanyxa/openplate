import CryptoKit
import Flutter
import Foundation
import UIKit
import onnxruntime_objc

/// All tensors, crops and model execution stay in this process. No frame networking.
final class LocalPlateRecognizer: NSObject, FlutterPlugin {
  private let cameraWorker = DispatchQueue(label: "openplate.camera.encode", qos: .utility)
  private let worker = DispatchQueue(label: "openplate.inference", qos: .userInitiated)
  private var environment: ORTEnv?
  private var detector: ORTSession?
  private var reader: ORTSession?
  private var vehicleModels: NativeVehicleModels?
  private var registeredPlates = Set<String>()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "openplate/local_recognition", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocalPlateRecognizer(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "encodeCameraFrame":
      guard let args = call.arguments as? [String: Any],
            let bytes = args["bytes"] as? FlutterStandardTypedData,
            let width = args["width"] as? Int,
            let height = args["height"] as? Int,
            let stride = args["bytesPerRow"] as? Int,
            width > 0, height > 0, width <= 4096, height <= 4096,
            stride >= width * 4, stride <= 32768, bytes.data.count >= stride * height else {
        result(FlutterError(code: "invalid_frame", message: "Ungültiger Kamera-Frame", details: nil))
        return
      }
      let orientation = args["orientation"] as? String ?? "portraitUp"
      cameraWorker.async {
        let frame = BgraVideoFrame(bytes: bytes.data, width: width, height: height, stride: stride)
        let jpeg = frame.cameraJPEG(orientation: orientation)
        DispatchQueue.main.async {
          if let jpeg { result(FlutterStandardTypedData(bytes: jpeg)) }
          else { result(FlutterError(code: "camera_encoding", message: "Kamerabild konnte nicht codiert werden", details: nil)) }
        }
      }
    case "configureVehicles":
      guard let args = call.arguments as? [String: Any],
            let plates = args["plates"] as? [String], plates.count <= 128,
            plates.allSatisfy({ $0.range(of: "^[A-ZÄÖÜ0-9]{1,10}$", options: .regularExpression) != nil }) else {
        result(FlutterError(code: "invalid_plates", message: "Ungültige Kennzeichenliste", details: nil))
        return
      }
      worker.async {
        self.configureVehiclePlates(plates)
        DispatchQueue.main.async { result(nil) }
      }
    case "initialize":
      Task {
        do {
          let paths = try await LocalModelStore.prepare()
          worker.async {
            do {
              try self.loadModels(paths)
              DispatchQueue.main.async { result("YOLO + PaddleOCR Latin · lokal auf dem iPhone") }
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
  func configureVehiclePlates(_ plates: [String]) { registeredPlates = Set(plates) }

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
    guard let detector, reader != nil else { throw LocalInferenceError.notReady }
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
      if let reading = try readPlate(frame, x: x1, y: y1, width: x2 - x1, height: y2 - y1) {
        readings.append(["plate": reading.text, "confidence": reading.confidence,
          "box": [Double(x1) / Double(frame.width), Double(y1) / Double(frame.height),
                  Double(x2 - x1) / Double(frame.width), Double(y2 - y1) / Double(frame.height)]])
      }
    }
    let eligible = readings.indices.filter {
      registeredPlates.contains(readings[$0]["plate"] as? String ?? "") &&
      (readings[$0]["confidence"] as? Double ?? 0) >= 0.8
    }
    if !eligible.isEmpty, let environment {
      if vehicleModels == nil { vehicleModels = try NativeVehicleModels(environment) }
      let boxes = try vehicleModels!.detect(frame)
      var assignments: [Int: Int] = [:]
      for index in eligible {
        guard let box = readings[index]["box"] as? [Double] else { continue }
        let plate = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        let matches = boxes.indices.filter { NativeVehicleModels.containsPlate(boxes[$0], plate) }
        if matches.count == 1 { assignments[index] = matches[0] }
      }
      for (index, vehicle) in assignments.sorted(by: { $0.key < $1.key }).prefix(2) {
        // Two distinct plate readings in one car crop are ambiguous, not evidence.
        guard assignments.values.filter({ $0 == vehicle }).count == 1 else { continue }
        guard boxes[vehicle].width * Double(frame.width) >= 72,
              boxes[vehicle].height * Double(frame.height) >= 72 else { continue }
        readings[index]["vehicle"] = try vehicleModels!.describe(frame, box: boxes[vehicle])
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

  func readPlate(_ frame: BgraVideoFrame, x: Int = 0, y: Int = 0,
                 width: Int? = nil, height: Int? = nil) throws -> (text: String, confidence: Double)? {
    guard let reader else { throw LocalInferenceError.notReady }
    let crop = frame.latinOCRInput(x: x, y: y, width: width ?? frame.width, height: height ?? frame.height)
    let input = try ORTValue(tensorData: NSMutableData(data: crop),
      elementType: .float, shape: [1, 3, 48, 320])
    let outputs = try reader.run(withInputs: ["x": input],
      outputNames: ["fetch_name_0"], runOptions: nil)
    guard let plate = outputs["fetch_name_0"] else { throw LocalInferenceError.contract }
    let shape = try plate.tensorTypeAndShapeInfo().shape.map { $0.intValue }
    guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[1] <= 400,
          shape[2] == Self.latinAlphabet.count else { throw LocalInferenceError.contract }
    return try Self.decodePlate(Self.floats(plate))
  }

  // Exact ordered character_dict from PaddlePaddle's pinned inference.yml.
  // CTC blank at zero; upstream appends space. Do not sort or deduplicate.
  static let latinAlphabet: [String] = [
    "", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E",
    "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U",
    "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k",
    "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "À",
    "Á", "Â", "Ã", "Ä", "Å", "Æ", "Ç", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï", "Ð",
    "Ñ", "Ò", "Ó", "Ô", "Õ", "Ö", "×", "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "ß", "à",
    "á", "â", "ã", "ä", "å", "æ", "ç", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ð",
    "ñ", "ò", "ó", "ô", "õ", "ö", "÷", "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ", "Ā",
    "ā", "Ă", "ă", "Ą", "ą", "Ć", "ć", "Ĉ", "ĉ", "Ċ", "ċ", "Č", "č", "Ď", "ď", "Đ",
    "đ", "Ē", "ē", "Ĕ", "ĕ", "Ė", "ė", "Ę", "ę", "Ě", "ě", "Ĝ", "ĝ", "Ğ", "ğ", "Ġ",
    "ġ", "Ģ", "ģ", "Ĥ", "ĥ", "Ħ", "ħ", "Ĩ", "ĩ", "Ī", "ī", "Ĭ", "ĭ", "Į", "į", "İ",
    "ı", "Ĳ", "ĳ", "Ĵ", "ĵ", "Ķ", "ķ", "ĸ", "Ĺ", "ĺ", "Ļ", "ļ", "Ľ", "ľ", "Ŀ", "ŀ",
    "Ł", "ł", "Ń", "ń", "Ņ", "ņ", "Ň", "ň", "ŉ", "Ŋ", "ŋ", "Ō", "ō", "Ŏ", "ŏ", "Ő",
    "ő", "Œ", "œ", "Ŕ", "ŕ", "Ŗ", "ŗ", "Ř", "ř", "Ś", "ś", "Ŝ", "ŝ", "Ş", "ş", "Š",
    "š", "Ţ", "ţ", "Ť", "ť", "Ŧ", "ŧ", "Ũ", "ũ", "Ū", "ū", "Ŭ", "ŭ", "Ů", "ů", "Ű",
    "ű", "Ų", "ų", "Ŵ", "ŵ", "Ŷ", "ŷ", "Ÿ", "Ź", "ź", "Ż", "ż", "Ž", "ž", "ſ", "ƀ",
    "Ɓ", "Ƃ", "ƃ", "Ƅ", "ƅ", "Ɔ", "Ƈ", "ƈ", "Ɖ", "Ɗ", "Ƌ", "ƌ", "ƍ", "Ǝ", "Ə", "Ɛ",
    "Ƒ", "ƒ", "Ɠ", "Ɣ", "ƕ", "Ɩ", "Ɨ", "Ƙ", "ƙ", "ƚ", "ƛ", "Ɯ", "Ɲ", "ƞ", "Ɵ", "Ơ",
    "ơ", "Ƣ", "ƣ", "Ƥ", "ƥ", "Ʀ", "Ƨ", "ƨ", "Ʃ", "ƪ", "ƫ", "Ƭ", "ƭ", "Ʈ", "Ư", "ư",
    "Ʊ", "Ʋ", "Ƴ", "ƴ", "Ƶ", "ƶ", "Ʒ", "Ƹ", "ƹ", "ƺ", "ƻ", "Ƽ", "ƽ", "ƾ", "ƿ", "ǀ",
    "ǁ", "ǂ", "ǃ", "Ǆ", "ǅ", "ǆ", "Ǉ", "ǈ", "ǉ", "Ǌ", "ǋ", "ǌ", "Ǎ", "ǎ", "Ǐ", "ǐ",
    "Ǒ", "ǒ", "Ǔ", "ǔ", "Ǖ", "ǖ", "Ǘ", "ǘ", "Ǚ", "ǚ", "Ǜ", "ǜ", "ǝ", "Ǟ", "ǟ", "Ǡ",
    "ǡ", "Ǣ", "ǣ", "Ǥ", "ǥ", "Ǧ", "ǧ", "Ǩ", "ǩ", "Ǫ", "ǫ", "Ǭ", "ǭ", "Ǯ", "ǯ", "ǰ",
    "Ǳ", "ǲ", "ǳ", "Ǵ", "ǵ", "Ƕ", "Ƿ", "Ǹ", "ǹ", "Ǻ", "ǻ", "Ǽ", "ǽ", "Ǿ", "ǿ", "Ȁ",
    "ȁ", "Ȃ", "ȃ", "Ȅ", "ȅ", "Ȇ", "ȇ", "Ȉ", "ȉ", "Ȋ", "ȋ", "Ȍ", "ȍ", "Ȏ", "ȏ", "Ȑ",
    "ȑ", "Ȓ", "ȓ", "Ȕ", "ȕ", "Ȗ", "ȗ", "Ș", "ș", "Ț", "ț", "Ȝ", "ȝ", "Ȟ", "ȟ", "Ƞ",
    "ȡ", "Ȣ", "ȣ", "Ȥ", "ȥ", "Ȧ", "ȧ", "Ȩ", "ȩ", "Ȫ", "ȫ", "Ȭ", "ȭ", "Ȯ", "ȯ", "Ȱ",
    "ȱ", "Ȳ", "ȳ", "ȴ", "ȵ", "ȶ", "ȷ", "ȸ", "ȹ", "Ⱥ", "Ȼ", "ȼ", "Ƚ", "Ⱦ", "ȿ", "ɀ",
    "Ɂ", "ɂ", "Ƀ", "Ʉ", "Ʌ", "Ɇ", "ɇ", "Ɉ", "ɉ", "Ɋ", "ɋ", "Ɍ", "ɍ", "Ɏ", "ɏ", "!",
    "\"", "#", "$", "%", "&", "'", "(", ")", "*", "+", ",", "-", ".", "/", ":", ";",
    "<", "=", ">", "?", "@", "[", "\\", "]", "_", "`", "{", "|", "}", "^", "~", "©",
    "®", "℉", "№", "Ω", "℮", "™", "∆", "✓", "✔", "✗", "✘", "✕", "☑", "☒", "●", "▪",
    "▫", "◼", "▶", "◀", "⬆", "¤", "¦", "§", "¨", "ª", "«", "¬", "¯", "°", "²", "³",
    "´", "µ", "¶", "¸", "¹", "º", "»", "¼", "½", "¾", "¿", "×", "‐", "‑", "‒", "—",
    "―", "‖", "‗", "‘", "’", "‚", "‛", "“", "”", "„", "‟", "†", "‡", "‣", "․", "…",
    "‧", "‰", "‴", "‵", "‶", "‷", "‸", "‹", "›", "※", "‼", "‽", "‾", "−", "₤", "₡",
    "₹", "₽", "₴", "₿", "¢", "€", "£", "¥", "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ",
    "Ⅸ", "Ⅹ", "Ⅺ", "Ⅻ", "ⅰ", "ⅱ", "ⅲ", "ⅳ", "ⅴ", "ⅵ", "ⅶ", "ⅷ", "ⅸ", "ⅹ", "ⅺ", "ⅻ",
    "➀", "➁", "➂", "➃", "➄", "➅", "➆", "➇", "➈", "➉", "➊", "➋", "➌", "➍", "➎", "➏",
    "➐", "➑", "➒", "➓", "❶", "❷", "❸", "❹", "❺", "❻", "❼", "❽", "❾", "❿", "①", "②",
    "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩", "↑", "→", "↓", "↕", "←", "↔", "⇒", "⇐",
    "⇔", "∀", "∃", "∄", "∴", "∵", "∝", "∞", "∩", "∪", "∂", "∫", "∬", "∭", "∮", "∯",
    "∰", "∑", "∏", "√", "∛", "∜", "∱", "∲", "∳", "∶", "∷", "∼", "∖", "∗", "≈", "≠",
    "≡", "≤", "≥", "⊂", "⊃", "⊥", "⊾", "⊿", "□", "∥", "∋", "ƒ", "′", "″", "À", "Á",
    "Â", "Ã", "Ä", "Å", "Æ", "Ç", "È", "É", "Ê", "Ë", "Ì", "Í", "Î", "Ï", "Ð", "Ñ",
    "Ò", "Ó", "Ô", "Õ", "Ö", "Ø", "Ù", "Ú", "Û", "Ü", "Ý", "Þ", "à", "á", "â", "ã",
    "ä", "å", "æ", "ç", "è", "é", "ê", "ë", "ì", "í", "î", "ï", "ð", "ñ", "ò", "ó",
    "ô", "õ", "ö", "ø", "ù", "ú", "û", "ü", "ý", "þ", "ÿ", "Α", "Β", "Γ", "Δ", "Ε",
    "Ζ", "Η", "Θ", "Ι", "Κ", "Λ", "Μ", "Ν", "Ξ", "Ο", "Π", "Ρ", "Σ", "Τ", "Υ", "Φ",
    "Χ", "Ψ", "Ω", "α", "β", "γ", "δ", "ε", "ζ", "η", "θ", "ι", "κ", "λ", "μ", "ν",
    "ξ", "ο", "π", "ρ", "σ", "ς", "τ", "υ", "φ", "χ", "ψ", "ω", "Å", "ℏ", "⌀", "⍺",
    "⍵", "𝑢", "𝜓", "०", "‥", "︽", "﹥", "•", "÷", "∕", "∙", "⋅", "·", "±", "∓", "∟",
    "∠", "∡", "∢", "℧", "☺", " ",
  ]

  static func decodePlate(_ probabilities: [Float]) throws -> (text: String, confidence: Double)? {
    let classes = latinAlphabet.count
    guard !probabilities.isEmpty, probabilities.count % classes == 0,
          probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
      throw LocalInferenceError.contract
    }
    var text = "", confidence = 0.0, count = 0, previous = -1
    // PaddleOCR is CTC: collapse adjacent duplicates, but a blank separates repeats.
    for step in 0..<(probabilities.count / classes) {
      let offset = step * classes
      let best = (0..<classes).max { probabilities[offset + $0] < probabilities[offset + $1] }!
      if best != 0 && best != previous {
        text += latinAlphabet[best]
        confidence += Double(probabilities[offset + best])
        count += 1
      }
      previous = best
    }
    let canonical = text.precomposedStringWithCanonicalMapping
    let allowed = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyzÄÖÜäöü -"
    guard count > 0, canonical.allSatisfy({ allowed.contains($0) }) else { return nil }
    let normalized = canonical.uppercased().filter { $0 != " " && $0 != "-" }
    guard !normalized.isEmpty, normalized.count <= 10 else { return nil }
    return (normalized, confidence / Double(count))
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
    ("latin-ocr-v5.onnx", "https://huggingface.co/PaddlePaddle/latin_PP-OCRv5_mobile_rec_onnx/resolve/89d3a50e2c27e2e7cceeab0e944c25c807d5db4f/inference.onnx", "7888113072263cb471b93f66dd5e2ad70548dc526fa1ace760d0d973dd121498"),
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

/// General vehicle detector + attributes + vehicle-specific ReID, all local CPU inference.
final class NativeVehicleModels {
  private let environment: ORTEnv
  let detector: ORTSession
  let attributes: ORTSession
  let reid: ORTSession
  static let types = ["car", "bus", "truck", "van"]
  static let colors = ["white", "gray", "yellow", "red", "green", "blue", "black"]

  init(_ environment: ORTEnv) throws {
    self.environment = environment
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(2)
    func model(_ name: String) throws -> ORTSession {
      let key = FlutterDartProject.lookupKey(forAsset: "assets/models/vehicle/\(name).onnx")
      guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
        throw LocalInferenceError.notReady
      }
      return try ORTSession(env: environment, modelPath: path, sessionOptions: options)
    }
    detector = try model("detector")
    attributes = try model("attributes")
    reid = try model("reid")
  }

  func detect(_ frame: BgraVideoFrame) throws -> [CGRect] {
    let input = try ORTValue(tensorData: NSMutableData(data: frame.vehicleInput(
      x: 0, y: 0, width: frame.width, height: frame.height, size: 256, bgr: true)),
      elementType: .float, shape: [1, 3, 256, 256])
    let outputs = try detector.run(withInputs: ["image": input],
      outputNames: ["locations", "scores", "priors"], runOptions: nil)
    guard let locations = outputs["locations"], let scores = outputs["scores"],
          let priors = outputs["priors"] else { throw LocalInferenceError.contract }
    return try Self.decodeSSD(locations: LocalPlateRecognizer.floats(locations),
      scores: LocalPlateRecognizer.floats(scores), priors: LocalPlateRecognizer.floats(priors))
  }

  static func decodeSSD(locations: [Float], scores: [Float], priors: [Float]) throws -> [CGRect] {
    guard locations.count == 5376, scores.count == 2688, priors.count == 10752,
          locations.allSatisfy({ $0.isFinite }), scores.allSatisfy({ $0.isFinite }),
          priors.allSatisfy({ $0.isFinite }) else { throw LocalInferenceError.contract }
    var candidates: [(CGRect, Float)] = []
    for i in 0..<1344 where scores[i * 2] >= 0.7 { // background_label_id = 1
      let p = i * 4
      let pw = Double(priors[p + 2] - priors[p]), ph = Double(priors[p + 3] - priors[p + 1])
      guard pw > 0, ph > 0 else { continue }
      let cx = Double(priors[p] + priors[p + 2]) / 2 + Double(locations[p] * priors[5376 + p]) * pw
      let cy = Double(priors[p + 1] + priors[p + 3]) / 2 + Double(locations[p + 1] * priors[5376 + p + 1]) * ph
      let sx = Double(locations[p + 2] * priors[5376 + p + 2])
      let sy = Double(locations[p + 3] * priors[5376 + p + 3])
      guard abs(sx) < 20, abs(sy) < 20 else { continue }
      let w = pw * exp(sx), h = ph * exp(sy)
      let rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
      // A truncated body is insufficient for enrollment or verification.
      guard rect.minX > 0.01, rect.minY > 0.01, rect.maxX < 0.99, rect.maxY < 0.99,
            rect.width > 0.05, rect.height > 0.05 else { continue }
      candidates.append((rect, scores[i * 2]))
    }
    candidates.sort { $0.1 > $1.1 }
    var selected: [CGRect] = []
    for (rect, _) in candidates {
      if selected.allSatisfy({ iou($0, rect) < 0.45 }) { selected.append(rect) }
      if selected.count == 4 { break }
    }
    return selected
  }

  static func iou(_ a: CGRect, _ b: CGRect) -> Double {
    let intersection = a.intersection(b)
    let area = intersection.isNull ? 0 : intersection.width * intersection.height
    return area / (a.width * a.height + b.width * b.height - area)
  }

  static func containsPlate(_ vehicle: CGRect, _ plate: CGRect) -> Bool {
    guard plate.width > 0, plate.height > 0 else { return false }
    let overlap = vehicle.intersection(plate)
    return !overlap.isNull && overlap.width * overlap.height >= plate.width * plate.height * 0.95 &&
      vehicle.width * vehicle.height > plate.width * plate.height * 4
  }

  func describe(_ frame: BgraVideoFrame, box: CGRect) throws -> [String: Any] {
    let x = Int(box.minX * Double(frame.width)), y = Int(box.minY * Double(frame.height))
    let w = min(frame.width - x, Int(ceil(box.width * Double(frame.width))))
    let h = min(frame.height - y, Int(ceil(box.height * Double(frame.height))))
    guard w >= 72, h >= 72 else { throw LocalInferenceError.contract }
    func input(_ size: Int, bgr: Bool) throws -> ORTValue {
      try ORTValue(tensorData: NSMutableData(data: frame.vehicleInput(x: x, y: y,
        width: w, height: h, size: size, bgr: bgr)), elementType: .float,
        shape: [1, 3, NSNumber(value: size), NSNumber(value: size)])
    }
    let attr = try attributes.run(withInputs: ["input": input(72, bgr: true)],
      outputNames: ["color/sink_port_0", "type/sink_port_0"], runOptions: nil)
    let embedding = try reid.run(withInputs: ["input": input(208, bgr: false)],
      outputNames: ["output"], runOptions: nil)
    guard let colorTensor = attr["color/sink_port_0"], let typeTensor = attr["type/sink_port_0"],
          let vectorTensor = embedding["output"] else { throw LocalInferenceError.contract }
    let colors = try LocalPlateRecognizer.floats(colorTensor), types = try LocalPlateRecognizer.floats(typeTensor)
    let vector = try LocalPlateRecognizer.floats(vectorTensor)
    guard colors.count == 7, types.count == 4, vector.count == 512,
          (colors + types).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
          vector.allSatisfy({ $0.isFinite }) else { throw LocalInferenceError.contract }
    let norm = sqrt(vector.reduce(0.0) { $0 + Double($1) * Double($1) })
    guard norm > 0, let preview = frame.vehiclePreview(x: x, y: y, width: w, height: h) else {
      throw LocalInferenceError.contract
    }
    let ci = colors.indices.max { colors[$0] < colors[$1] }!, ti = types.indices.max { types[$0] < types[$1] }!
    return ["type": Self.types[ti], "type_confidence": Double(types[ti]),
      "color": Self.colors[ci], "color_confidence": Double(colors[ci]),
      "embedding": vector.map { Double($0) / norm }, "preview": FlutterStandardTypedData(bytes: preview)]
  }
}

struct BgraVideoFrame {
  let bytes: Data
  let width: Int
  let height: Int
  let stride: Int

  func cameraJPEG(orientation: String) -> Data? {
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
              CGImageAlphaInfo.noneSkipFirst.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
    let rotation: UIImage.Orientation
    switch orientation {
    case "landscapeLeft": rotation = .up
    case "landscapeRight": rotation = .down
    case "portraitDown": rotation = .left
    default: rotation = .right
    }
    let source = UIImage(cgImage: image, scale: 1, orientation: rotation)
    let scale = min(1, 640 / max(source.size.width, source.size.height))
    let size = CGSize(width: source.size.width * scale, height: source.size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
      source.draw(in: CGRect(origin: .zero, size: size))
    }
    guard let jpeg = rendered.jpegData(compressionQuality: 0.55), jpeg.count <= 165000 else { return nil }
    return jpeg
  }

  func vehicleInput(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int,
                    size: Int, bgr: Bool) -> Data {
    let rgb = rgbResized(x: x, y: y, width: cropWidth, height: cropHeight,
                        targetWidth: size, targetHeight: size)
    var tensor = [Float](repeating: 0, count: 3 * size * size)
    for pixel in 0..<(size * size) {
      for channel in 0..<3 {
        tensor[channel * size * size + pixel] = Float(rgb[pixel * 3 + (bgr ? 2 - channel : channel)])
      }
    }
    return tensor.withUnsafeBytes { Data($0) }
  }

  func vehiclePreview(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> Data? {
    guard let provider = CGDataProvider(data: bytes as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue |
              CGImageAlphaInfo.noneSkipFirst.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let crop = image.cropping(to: CGRect(x: x, y: y, width: cropWidth, height: cropHeight)) else { return nil }
    let scale = min(1, 480.0 / Double(max(cropWidth, cropHeight)))
    let size = CGSize(width: Double(cropWidth) * scale, height: Double(cropHeight) * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { _ in
      UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
    }.jpegData(compressionQuality: 0.65)
  }

  /// PaddleOCR reference: aspect-preserving BGR, CHW, [-1,1], right-zero padding.
  func latinOCRInput(x: Int, y: Int, width cropWidth: Int, height cropHeight: Int) -> Data {
    let resizedWidth = min(320, max(1, Int(ceil(48 * Double(cropWidth) / Double(cropHeight)))))
    let rgb = rgbResized(x: x, y: y, width: cropWidth, height: cropHeight,
                        targetWidth: resizedWidth, targetHeight: 48)
    var tensor = [Float](repeating: 0, count: 3 * 48 * 320)
    for row in 0..<48 {
      for column in 0..<resizedWidth {
        for channel in 0..<3 {
          tensor[channel * 48 * 320 + row * 320 + column] =
            Float(rgb[(row * resizedWidth + column) * 3 + 2 - channel]) / 127.5 - 1
        }
      }
    }
    return tensor.withUnsafeBytes { Data($0) }
  }

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
