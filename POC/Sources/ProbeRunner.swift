import Foundation
import Combine
import onnxruntime_objc

/// 数值一致性探针。
///
/// 用 PC 端导出的 `probe_input.bin`（1×3×224×224 float32）跑一遍模型，
/// 取 CLS token（前 384 个）做 L2 归一化，再与 `probe_expected.txt` 比较。
///
/// 注意：这里刻意只用最保守的 API（env / session / ORTValue / tensorData），
/// 不设置图优化级别、不读取 tensorShape，避免不同 ORT 版本的接口差异。
enum ProbePhase: String {
    case idle = "未运行"
    case running = "推理中…"
    case done = "完成"
    case failed = "失败"
}

struct ProbeResult {
    let cosine: Double
    let maxDiff: Double
    let elapsedMs: Double
    let log: String
}

enum ProbeError: LocalizedError {
    case missingFile(String)
    case badInput(String)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let message): return message
        case .badInput(let message): return message
        case .badOutput(let message): return message
        }
    }
}

final class ProbeRunner: ObservableObject {
    @Published var log: String = ""
    @Published var cosine: Double = .nan
    @Published var maxAbsDiff: Double = .nan
    @Published var elapsedMs: Double = .nan
    @Published var phase: ProbePhase = .idle

    private static let inputShape = [1, 3, 224, 224]
    private static let width = 384

    func run() {
        phase = .running
        log = ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try ProbeRunner.runSync()
                DispatchQueue.main.async {
                    self.cosine = result.cosine
                    self.maxAbsDiff = result.maxDiff
                    self.elapsedMs = result.elapsedMs
                    self.log = result.log
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

    private static func runSync() throws -> ProbeResult {
        guard let modelURL = Bundle.main.url(forResource: "dinov2-small-fp16", withExtension: "onnx") else {
            throw ProbeError.missingFile("模型没打包进 App：检查 Resources 是否加入 target")
        }
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

        let started = Date()

        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: options)

        let inputNames = try session.inputNames()
        guard let inputName = inputNames.first else {
            throw ProbeError.badOutput("模型没有输入")
        }
        let tensor = try ORTValue(
            tensorData: NSMutableData(data: inputData),
            elementType: .float,
            shape: inputShape.map { NSNumber(value: $0) }
        )
        let outputNames = try session.outputNames()
        let outputs = try session.run(
            withInputs: [inputName: tensor],
            outputNames: Set(outputNames),
            runOptions: nil
        )
        guard let firstOutput = outputs.values.first else {
            throw ProbeError.badOutput("模型没有输出")
        }

        let outputData = try firstOutput.tensorData() as Data
        let floatCount = outputData.count / 4
        guard floatCount > 0, floatCount % width == 0 else {
            throw ProbeError.badOutput("输出字节数 \(outputData.count) 不是 \(width) 的整数倍")
        }
        let tokens = floatCount / width

        // 第 0 个 token 是 CLS
        var cls = [Double](repeating: 0, count: width)
        outputData.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<width {
                cls[i] = Double(floats[i])
            }
        }
        var norm = 0.0
        for value in cls { norm += value * value }
        norm = sqrt(norm)
        if norm > 1e-9 {
            for i in 0..<width { cls[i] /= norm }
        }

        guard expected.count == width else {
            throw ProbeError.badOutput("probe_expected.txt 有 \(expected.count) 个数，应为 \(width)")
        }

        var dot = 0.0, normA = 0.0, normB = 0.0, maxDiff = 0.0
        for i in 0..<width {
            dot += cls[i] * expected[i]
            normA += cls[i] * cls[i]
            normB += expected[i] * expected[i]
            maxDiff = max(maxDiff, abs(cls[i] - expected[i]))
        }
        let cosine = dot / (sqrt(normA) * sqrt(normB))
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        let verdict: String
        if cosine >= 0.999 {
            verdict = "✅ 通过：ORT 在 iOS 上数值可信，可以继续移植"
        } else if cosine >= 0.99 {
            verdict = "⚠️ 接近：可能是预处理/精度差异，看 maxDiff"
        } else {
            verdict = "❌ 不通过：先排查模型与输入是否一致"
        }

        let log = """
        模型：\(modelURL.lastPathComponent)
        输入：\(inputShape.map(String.init).joined(separator: "x"))，\(inputData.count) 字节
        输出：\(tokens) token × \(width)（\(floatCount) 个 float）
        余弦：\(String(format: "%.8f", cosine))
        最大单项差：\(String(format: "%.8f", maxDiff))
        耗时：\(String(format: "%.0f", elapsedMs)) ms

        \(verdict)
        """
        return ProbeResult(cosine: cosine, maxDiff: maxDiff, elapsedMs: elapsedMs, log: log)
    }
}
