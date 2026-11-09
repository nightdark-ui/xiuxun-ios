import Foundation
import Combine
import onnxruntime_objc

/// 数值一致性探针（v2）。
///
/// 相比 v1 的两点改进：
/// 1. **模型只加载一次**，之后连续跑 3 次，分别计时 —— 这样才能看出"纯推理"耗时
/// 2. 结果里同时给出加载耗时和每次推理耗时，用来估算整次搜索的时间
enum ProbePhase: String {
    case idle = "未运行"
    case running = "推理中…"
    case done = "完成"
    case failed = "失败"
}

struct ProbeResult {
    let cosine: Double
    let maxDiff: Double
    let loadMs: Double
    let runMs: [Double]
    let message: String
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
    @Published var message: String = ""
    @Published var cosine: Double = .nan
    @Published var maxAbsDiff: Double = .nan
    @Published var loadMs: Double = .nan
    @Published var runMs: [Double] = []
    @Published var phase: ProbePhase = .idle

    private static let inputShape = [1, 3, 224, 224]
    private static let width = 384

    // 只加载一次，后续复用
    private static var cachedEnv: ORTEnv?
    private static var cachedSession: ORTSession?
    private static var cachedInputName: String = ""
    private static var cachedOutputNames: Set<String> = []
    private static let lock = NSLock()

    func run() {
        phase = .running
        message = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try ProbeRunner.runSync()
                DispatchQueue.main.async {
                    self.cosine = result.cosine
                    self.maxAbsDiff = result.maxDiff
                    self.loadMs = result.loadMs
                    self.runMs = result.runMs
                    self.message = result.message
                    self.phase = .done
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.message = "❌ \(error.localizedDescription)"
                }
            }
        }
    }

    private static func ensureSession() throws -> Double {
        lock.lock()
        defer { lock.unlock() }
        if cachedSession != nil { return 0 }

        guard let modelURL = Bundle.main.url(forResource: "dinov2-small-fp16", withExtension: "onnx") else {
            throw ProbeError.missingFile("模型没打包进 App：检查 Resources 是否加入 target")
        }
        let started = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)
        let names = try session.inputNames()
        guard let first = names.first else { throw ProbeError.badOutput("模型没有输入") }
        cachedEnv = env
        cachedSession = session
        cachedInputName = first
        cachedOutputNames = Set(try session.outputNames())
        return Date().timeIntervalSince(started) * 1000
    }

    private static func runSync() throws -> ProbeResult {
        guard let inputURL = Bundle.main.url(forResource: "probe_input", withExtension: "bin") else {
            throw ProbeError.missingFile("缺 probe_input.bin")
        }
        guard let expectedURL = Bundle.main.url(forResource: "probe_expected", withExtension: "txt") else {
            throw ProbeError.missingFile("缺 probe_expected.txt")
        }

        let inputData = try Data(contentsOf: inputURL)
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        let elementCount = inputShape.reduce(1, *)
        guard inputData.count == elementCount * 4 else {
            throw ProbeError.badInput("probe_input.bin 大小不符：\(inputData.count) 字节，应为 \(elementCount * 4)")
        }
        let loadMs = try ensureSession()
        guard let session = cachedSession else { throw ProbeError.badOutput("session 未就绪") }

        var timings: [Double] = []
        var lastCls = [Double](repeating: 0, count: width)
        var tokens = 0

        for _ in 0..<3 {
            let started = Date()
            let tensor = try ORTValue(
                tensorData: NSMutableData(data: inputData),
                elementType: .float,
                shape: inputShape.map { NSNumber(value: $0) }
            )
            let outputs = try session.run(
                withInputs: [cachedInputName: tensor],
                outputNames: cachedOutputNames,
                runOptions: nil
            )
            guard let firstOutput = outputs.values.first else { throw ProbeError.badOutput("模型没有输出") }
            let outputData = try firstOutput.tensorData() as Data
            let floatCount = outputData.count / 4
            guard floatCount > 0, floatCount % width == 0 else {
                throw ProbeError.badOutput("输出字节数 \(outputData.count) 不是 \(width) 的整数倍")
            }
            tokens = floatCount / width

            var cls = [Double](repeating: 0, count: width)
            outputData.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self)
                for i in 0..<width { cls[i] = Double(floats[i]) }
            }
            var norm = 0.0
            for v in cls { norm += v * v }
            norm = sqrt(norm)
            if norm > 1e-9 { for i in 0..<width { cls[i] /= norm } }
            lastCls = cls
            timings.append(Date().timeIntervalSince(started) * 1000)
        }

        guard expected.count == width else {
            throw ProbeError.badOutput("probe_expected.txt 有 \(expected.count) 个数，应为 \(width)")
        }

        var dot = 0.0, normA = 0.0, normB = 0.0, maxDiff = 0.0
        for i in 0..<width {
            dot += lastCls[i] * expected[i]
            normA += lastCls[i] * lastCls[i]
            normB += expected[i] * expected[i]
            maxDiff = max(maxDiff, abs(lastCls[i] - expected[i]))
        }
        let cosine = dot / (sqrt(normA) * sqrt(normB))

        let verdict: String
        if cosine >= 0.999 {
            verdict = "✅ 通过：数值与 PC/安卓一致"
        } else if cosine >= 0.99 {
            verdict = "⚠️ 接近：可能有精度差异"
        } else {
            verdict = "❌ 不通过"
        }

        let runs = timings.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        let message = """
        模型：dinov2-small-fp16.onnx
        输入：1x3x224x224，\(inputData.count) 字节
        输出：\(tokens) token × \(width)

        加载模型：\(loadMs > 0 ? String(format: "%.0f", loadMs) : "复用上次") ms
        推理三次：\(runs) ms
        余弦：\(String(format: "%.8f", cosine))
        最大单项差：\(String(format: "%.8f", maxDiff))

        \(verdict)
        """
        return ProbeResult(cosine: cosine, maxDiff: maxDiff, loadMs: loadMs, runMs: timings, message: message)
    }
}
