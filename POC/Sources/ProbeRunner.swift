import Foundation
import Combine
import onnxruntime_objc

/// 综合探针 v3：
///   A. 图像链路：JPEG → 灰度 → 裁切 → BICUBIC 224 → 归一化，与 PC 的张量比对
///   B. 模型链路：用自己的张量跑模型，与 PC 的特征比对
///   C. 速度：模型只加载一次，连跑 3 次取最快
enum ProbePhase: String {
    case idle = "未运行"
    case running = "运行中…"
    case done = "完成"
    case failed = "失败"
}

struct ProbeReport {
    // A. 图像链路
    let tensorCosine: Double
    let tensorMaxDiff: Double
    let tensorMeanDiff: Double
    // B. 模型链路
    let featureCosine: Double
    let featureMaxDiff: Double
    // C. 速度
    let loadMs: Double
    let runMs: [Double]
    let log: String
}

enum ProbeError: LocalizedError {
    case missingFile(String)
    case badInput(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let m): return m
        case .badInput(let m): return m
        case .badOutput(let m): return m
        }
    }
}

final class ProbeRunner: ObservableObject {
    @Published var log: String = ""
    @Published var tensorCosine: Double = .nan
    @Published var tensorMaxDiff: Double = .nan
    @Published var featureCosine: Double = .nan
    @Published var runMs: Double = .nan
    @Published var loadMs: Double = .nan
    @Published var phase: ProbePhase = .idle

    private static let size = 224
    private static let width = 384

    private static var cachedSession: ORTSession?
    private static var cachedInputName = ""
    private static var cachedOutputNames: Set<String> = []
    private static let lock = NSLock()

    func run() {
        phase = .running
        log = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let report = try ProbeRunner.runSync()
                DispatchQueue.main.async {
                    self.tensorCosine = report.tensorCosine
                    self.tensorMaxDiff = report.tensorMaxDiff
                    self.featureCosine = report.featureCosine
                    self.loadMs = report.loadMs
                    self.runMs = report.runMs.min() ?? .nan
                    self.log = report.log
                    self.phase = .done
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.log = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private static func ensureSession() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        if cachedSession != nil { return 0 }
        guard let modelURL = Bundle.main.url(forResource: "dinov2-small-fp16", withExtension: "onnx") else {
            throw ProbeError.missingFile("模型没打包进 App")
        }
        let started = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        guard let first = try session.inputNames().first else {
            throw ProbeError.badOutput("模型没有输入")
        }
        cachedSession = session
        cachedInputName = first
        cachedOutputNames = Set(try session.outputNames())
        return Date().timeIntervalSince(started) * 1000
    }

    private static func runSync() throws -> ProbeReport {
        guard let imageURL = Bundle.main.url(forResource: "probe_image", withExtension: "jpg") else {
            throw ProbeError.missingFile("缺 probe_image.jpg")
        }
        guard let refURL = Bundle.main.url(forResource: "probe_input", withExtension: "bin") else {
            throw ProbeError.missingFile("缺 probe_input.bin")
        }
        guard let expectedURL = Bundle.main.url(forResource: "probe_expected", withExtension: "txt") else {
            throw ProbeError.missingFile("缺 probe_expected.txt")
        }

        // ---------- A. 图像链路 ----------
        let prepared = try PilImaging.prepareTensor(from: imageURL, size: size, fraction: 1.0)
        let ours = prepared.tensor

        let refData = try Data(contentsOf: refURL)
        guard refData.count == ours.count * 4 else {
            throw ProbeError.badInput("probe_input.bin 大小 \(refData.count)，应为 \(ours.count * 4)")
        }
        var reference = [Float](repeating: 0, count: ours.count)
        refData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<ours.count { reference[i] = floats[i] }
        }

        var tDot = 0.0, tA = 0.0, tB = 0.0, tMax = 0.0, tAbs = 0.0
        for i in 0..<ours.count {
            let a = Double(ours[i])
            let b = Double(reference[i])
            tDot += a * b
            tA += a * a
            tB += b * b
            let d = abs(a - b)
            tMax = max(tMax, d)
            tAbs += d
        }
        let tensorCosine = tDot / (sqrt(tA) * sqrt(tB))
        let tensorMeanDiff = tAbs / Double(ours.count)

        // ---------- B. 模型链路 ----------
        let loadMs = try ensureSession()
        guard let session = cachedSession else { throw ProbeError.badOutput("session 未就绪") }
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        var timings: [Double] = []
        var featureCosine = 0.0
        var featureMaxDiff = 0.0

        for _ in 0..<3 {
            let started = Date()
            let data = Data(bytes: ours, count: ours.count * 4)
            let tensor = try ORTValue(
                tensorData: NSMutableData(data: data),
                elementType: .float,
                shape: [1, 3, NSNumber(value: size), NSNumber(value: size)]
            )
            let outputs = try session.run(
                withInputs: [cachedInputName: tensor],
                outputNames: cachedOutputNames,
                runOptions: nil
            )
            guard let firstOutput = outputs.values.first else { throw ProbeError.badOutput("模型没有输出") }
            let outputData = try firstOutput.tensorData() as Data
            let floatCount = outputData.count / 4
            guard floatCount >= width else { throw ProbeError.badOutput("输出太小") }

            var cls = [Double](repeating: 0, count: width)
            outputData.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<width { cls[i] = Double(floats[i]) }
            }
            var norm = 0.0
            for v in cls { norm += v * v }
            norm = sqrt(norm)
            if norm > 1e-9 { for i in 0..<width { cls[i] /= norm } }

            var dot = 0.0, na = 0.0, nb = 0.0, mx = 0.0
            for i in 0..<min(width, expected.count) {
                dot += cls[i] * expected[i]
                na += cls[i] * cls[i]
                nb += expected[i] * expected[i]
                mx = max(mx, abs(cls[i] - expected[i]))
            }
            featureCosine = dot / (sqrt(na) * sqrt(nb))
            featureMaxDiff = mx
            timings.append(Date().timeIntervalSince(started) * 1000)
        }

        let tensorVerdict = tensorCosine >= 0.9999
            ? "✅ 图像链路一致"
            : (tensorCosine >= 0.999 ? "⚠️ 图像链路接近，可能有 1 级灰度差" : "❌ 图像链路不一致")
        let featureVerdict = featureCosine >= 0.999
            ? "✅ 特征一致"
            : (featureCosine >= 0.99 ? "⚠️ 特征接近" : "❌ 特征不一致")

        let runs = timings.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        let log = """
        【A. 图像链路】JPEG → 灰度 → 裁切 → BICUBIC \(size) → 归一化
          原图：\(prepared.gray.width)×\(prepared.gray.height)
          张量余弦：\(String(format: "%.8f", tensorCosine))
          最大单项差：\(String(format: "%.6f", tMax))
          平均单项差：\(String(format: "%.6f", tensorMeanDiff))
          \(tensorVerdict)

        【B. 特征链路】用本机张量跑模型
          特征余弦：\(String(format: "%.8f", featureCosine))
          最大单项差：\(String(format: "%.8f", featureMaxDiff))
          \(featureVerdict)

        【C. 速度】
          加载模型：\(loadMs > 0 ? String(format: "%.0f", loadMs) : "复用") ms
          三次推理：\(runs) ms
        """
        return ProbeReport(
            tensorCosine: tensorCosine,
            tensorMaxDiff: tMax,
            tensorMeanDiff: tensorMeanDiff,
            featureCosine: featureCosine,
            featureMaxDiff: featureMaxDiff,
            loadMs: loadMs,
            runMs: timings,
            log: log
        )
    }
}
