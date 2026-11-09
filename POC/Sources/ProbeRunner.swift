import Foundation
import Combine
import onnxruntime_objc

/// 计算后端
enum ComputeMode: String {
    case cpu = "CPU"
    case coreML = "CoreML/ANE"
}

/// 单次测试的结果
struct RunSummary {
    var mode: ComputeMode
    var ok: Bool
    var note: String = ""
    var tensorCosine: Double = .nan
    var featureCosine: Double = .nan
    var sessionMs: Double = .nan
    var runMs: Double = .nan
    var detail: String = ""
}

enum ProbePhase: String {
    case idle = "未运行"
    case running = "运行中…"
    case done = "完成"
    case failed = "失败"
}

struct ProbeReport {
    var tensorCosine: Double
    var tensorMaxDiff: Double
    var tensorMeanDiff: Double
    var sessionMs: Double
    var runMs: Double
    var featureCosine: Double
    var detail: String
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
    @Published var phase: ProbePhase = .idle
    @Published var cpuSummary: RunSummary?
    @Published var coreMLSummary: RunSummary?
    @Published var lastCrashStep: String = ProbeTrace.last
    @Published var lastNote: String = ProbeTrace.lastNote
    @Published var phaseText: String = ""

    private static let size = 224
    private static let width = 384

    /// 图像链路只算一次，两种后端共用同一份张量
    private var cachedTensor: [Float]?
    private var cachedReference: [Float]?
    private var cachedExpected: [Double]?
    private var tensorCheck: (cosine: Double, maxDiff: Double, meanDiff: Double) = (.nan, .nan, .nan)
    private var imageSize = (0, 0)

    func run(mode: ComputeMode) {
        if phase == .running { return }
        phase = .running
        phaseText = "\(mode.rawValue) 运行中…"
        ProbeTrace.clear()
        ProbeTrace.clearNote()
        ProbeTrace.mark(.start)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let summary = try self.runSync(mode: mode)
                DispatchQueue.main.async {
                    if mode == .cpu { self.cpuSummary = summary } else { self.coreMLSummary = summary }
                    self.phase = .done
                    self.phaseText = "\(mode.rawValue) 完成"
                    self.lastCrashStep = ""
                    self.lastNote = ProbeTrace.lastNote
                    self.phase = summary.ok ? .done : .failed
                }
            } catch {
                let summary = RunSummary(
                    mode: mode,
                    ok: false,
                    note: "中断于「\(ProbeTrace.last)」",
                    detail: error.localizedDescription
                )
                DispatchQueue.main.async {
                    if mode == .cpu { self.cpuSummary = summary } else { self.coreMLSummary = summary }
                    self.phase = .failed
                    self.phaseText = "\(mode.rawValue) 失败"
                    self.lastCrashStep = ProbeTrace.last
                    self.lastNote = ProbeTrace.lastNote
                }
            }
        }
    }

    // MARK: - 图像链路（只算一次）

    private func prepareInputs() throws -> (ours: [Float], reference: [Float], expected: [Double]) {
        if let ours = cachedTensor, let reference = cachedReference, let expected = cachedExpected {
            return (ours, reference, expected)
        }
        guard let imageURL = Bundle.main.url(forResource: "probe_image", withExtension: "jpg") else {
            throw ProbeError.missingFile("缺 probe_image.jpg")
        }
        guard let refURL = Bundle.main.url(forResource: "probe_input", withExtension: "bin") else {
            throw ProbeError.missingFile("缺 probe_input.bin")
        }
        guard let expectedURL = Bundle.main.url(forResource: "probe_expected", withExtension: "txt") else {
            throw ProbeError.missingFile("缺 probe_expected.txt")
        }

        let prepared = try PilImaging.prepareTensor(from: imageURL, size: Self.size, fraction: 1.0)
        let ours = prepared.tensor
        imageSize = (prepared.gray.width, prepared.gray.height)

        let refData = try Data(contentsOf: refURL)
        guard refData.count == ours.count * 4 else {
            throw ProbeError.badInput("probe_input.bin 大小 \(refData.count)，应为 \(ours.count * 4)")
        }
        var reference = [Float](repeating: 0, count: ours.count)
        refData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<ours.count { reference[i] = base[i] }
        }

        var dot = 0.0, normA = 0.0, normB = 0.0, maxDiff = 0.0, absSum = 0.0
        for i in 0..<ours.count {
            let a = Double(ours[i])
            let b = Double(reference[i])
            dot += a * b
            normA += a * a
            normB += b * b
            let d = abs(a - b)
            maxDiff = max(maxDiff, d)
            absSum += d
        }
        tensorCheck = (dot / (sqrt(normA) * sqrt(normB)), maxDiff, absSum / Double(ours.count))

        var nanCount = 0, infCount = 0
        var minValue = Double.greatestFiniteMagnitude
        var maxValue = -Double.greatestFiniteMagnitude
        for value in ours {
            let d = Double(value)
            if d.isNaN { nanCount += 1; continue }
            if d.isInfinite { infCount += 1; continue }
            minValue = Swift.min(minValue, d)
            maxValue = Swift.max(maxValue, d)
        }
        ProbeTrace.note(
            "元素 \(ours.count)；NaN \(nanCount)；Inf \(infCount)；" +
            "min \(String(format: "%.4f", minValue))；max \(String(format: "%.4f", maxValue))"
        )

        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

        cachedTensor = ours
        cachedReference = reference
        cachedExpected = expected
        return (ours, reference, expected)
    }

    // MARK: - 单次推理

    private static func inferOnce(
        modelPath: String,
        values: [Float],
        mode: ComputeMode
    ) throws -> (cls: [Double], sessionMs: Double, runMs: Double, note: String) {
        var note = ""
        let sessionStarted = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)

        if mode == .coreML {
            let coremlOptions = ORTCoreMLExecutionProviderOptions()
            coremlOptions.useCPUOnly = false
            coremlOptions.enableOnSubgraphs = false
            coremlOptions.onlyEnableForDevicesWithANE = false
            do {
                // 注意：这个方法的返回值在 Swift 里被推断为 Void，不能当 Bool 用
                try options.appendCoreMLExecutionProvider(with: coremlOptions)
                note = "已请求 CoreML EP"
            } catch {
                note = "CoreML EP 启用失败：\(error.localizedDescription)"
            }
        }

        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        let inputNames = try session.inputNames()
        guard let inputName = inputNames.first else { throw ProbeError.badOutput("模型没有输入") }
        let outputNames = Set(try session.outputNames())
        let sessionMs = Date().timeIntervalSince(sessionStarted) * 1000

        let runStarted = Date()
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let shape: [NSNumber] = [
            NSNumber(value: 1),
            NSNumber(value: 3),
            NSNumber(value: size),
            NSNumber(value: size),
        ]
        let tensor = try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .float,
            shape: shape
        )
        ProbeTrace.mark(.runSession)
        let outputs = try session.run(
            withInputs: [inputName: tensor],
            outputNames: outputNames,
            runOptions: nil
        )
        ProbeTrace.mark(.readOutput)
        guard let firstOutput = outputs.values.first else { throw ProbeError.badOutput("模型没有输出") }
        let outputData = try firstOutput.tensorData() as Data
        let floatCount = outputData.count / 4
        guard floatCount >= width else { throw ProbeError.badOutput("输出太小：\(floatCount)") }

        var cls = [Double](repeating: 0, count: width)
        outputData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<width { cls[i] = Double(base[i]) }
        }
        let runMs = Date().timeIntervalSince(runStarted) * 1000
        return (cls, sessionMs, runMs, note)
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        var result = values
        var norm = 0.0
        for v in result { norm += v * v }
        norm = sqrt(norm)
        if norm > 1e-9 { for i in 0..<result.count { result[i] /= norm } }
        return result
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        let limit = min(a.count, b.count)
        for i in 0..<limit {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        return dot / (sqrt(na) * sqrt(nb))
    }

    // MARK: - 主流程

    private func runSync(mode: ComputeMode) throws -> RunSummary {
        guard let modelURL = Bundle.main.url(forResource: "dinov2-small-fp16", withExtension: "onnx") else {
            throw ProbeError.missingFile("模型没打包进 App")
        }
        let inputs = try prepareInputs()

        // 预热一次 + 计时一次，取较快的
        ProbeTrace.mark(mode == .cpu ? .runReference : .runOurs)
        let first = try Self.inferOnce(modelPath: modelURL.path, values: inputs.ours, mode: mode)
        let second = try Self.inferOnce(modelPath: modelURL.path, values: inputs.ours, mode: mode)

        let cls = Self.normalize(second.cls)
        let featureCosine = Self.cosine(cls, inputs.expected)
        ProbeTrace.mark(.done)

        let detail = """
        图像链路：余弦 \(String(format: "%.8f", tensorCheck.cosine))，最大差 \(String(format: "%.6f", tensorCheck.maxDiff))，平均差 \(String(format: "%.6f", tensorCheck.meanDiff))
        原图：\(imageSize.0)×\(imageSize.1)
        \(first.note.isEmpty ? "" : first.note + "\n")建 session：\(String(format: "%.0f", first.sessionMs)) / \(String(format: "%.0f", second.sessionMs)) ms
        推理：\(String(format: "%.0f", first.runMs)) / \(String(format: "%.0f", second.runMs)) ms
        特征余弦：\(String(format: "%.8f", featureCosine))
        """
        ProbeTrace.note(ProbeTrace.lastNote + "；\(mode.rawValue) 特征余弦 " + String(format: "%.8f", featureCosine))

        return RunSummary(
            mode: mode,
            ok: true,
            note: second.note,
            tensorCosine: tensorCheck.cosine,
            featureCosine: featureCosine,
            sessionMs: second.sessionMs,
            runMs: min(first.runMs, second.runMs),
            detail: detail
        )
    }
}
