import Foundation
import Combine
import onnxruntime_objc

/// 计算后端 / 配置
enum ComputeMode: String, CaseIterable {
    case cpu1 = "CPU 1线程"
    case cpu4 = "CPU 4线程"
    case xnnpackAll = "XNNPACK 全核"
    case coreML = "CoreML"
    case coreMLANE = "CoreML(仅ANE)"
}

enum DeviceInfo {
    /// 物理核心数（含能效核）
    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }

    /// 建议给 XNNPACK 用的线程数：留一个核给 UI 和系统
    static var recommendedThreads: Int { max(1, coreCount - 1) }

    static var memoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0 / 1024.0
    }

    /// 机型标识（如 iPhone17,1）
    static var machine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        return String(cString: model)
    }

    static var summary: String {
        String(
            format: "机型 %@ · %d 核 · 内存 %.1f GB · 建议线程 %d",
            machine, coreCount, memoryGB, recommendedThreads
        )
    }
}

struct RunSummary {
    var mode: ComputeMode
    var ok: Bool
    var note: String = ""
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
    @Published var phaseText: String = ""
    @Published var summaries: [ComputeMode: RunSummary] = [:]
    @Published var lastCrashStep: String = ProbeTrace.last
    @Published var lastNote: String = ProbeTrace.lastNote

    private static let size = 224
    private static let width = 384

    private var cachedTensor: [Float]?
    private var cachedExpected: [Double]?
    private var tensorCheck: (cosine: Double, maxDiff: Double, meanDiff: Double) = (.nan, .nan, .nan)

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
                    self.summaries[mode] = summary
                    self.phase = summary.ok ? .done : .failed
                    self.phaseText = "\(mode.rawValue) \(summary.ok ? "完成" : "失败")"
                    self.lastCrashStep = ""
                    self.lastNote = ProbeTrace.lastNote
                }
            } catch {
                let summary = RunSummary(
                    mode: mode,
                    ok: false,
                    note: "中断于「\(ProbeTrace.last)」",
                    detail: error.localizedDescription
                )
                DispatchQueue.main.async {
                    self.summaries[mode] = summary
                    self.phase = .failed
                    self.phaseText = "\(mode.rawValue) 失败"
                    self.lastCrashStep = ProbeTrace.last
                    self.lastNote = ProbeTrace.lastNote
                }
            }
        }
    }

    // MARK: - 图像链路（只算一次，所有后端共用）

    private func prepareInputs() throws -> [Float] {
        if let ours = cachedTensor, cachedExpected != nil { return ours }
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

        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }

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
            "图像余弦 \(String(format: "%.8f", tensorCheck.cosine))" +
            "；原图 \(prepared.gray.width)×\(prepared.gray.height)" +
            "；NaN \(nanCount)；min \(String(format: "%.4f", minValue))；max \(String(format: "%.4f", maxValue))"
        )

        cachedTensor = ours
        cachedExpected = expected
        return ours
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

        switch mode {
        case .cpu1:
            try options.setIntraOpNumThreads(1)
            note = "1 线程"
        case .cpu4:
            try options.setIntraOpNumThreads(4)
            note = "4 线程"
        case .xnnpackAll:
            try options.setIntraOpNumThreads(1)
            let threads = DeviceInfo.recommendedThreads
            let xnn = ORTXnnpackExecutionProviderOptions()
            xnn.intra_op_num_threads = Int32(threads)
            do {
                try options.appendXnnpackExecutionProvider(with: xnn)
                note = "XNNPACK \(threads) 线程（全核）"
            } catch {
                note = "XNNPACK 启用失败：\(error.localizedDescription)"
            }
        case .coreML:
            try options.setIntraOpNumThreads(1)
            let coreml = ORTCoreMLExecutionProviderOptions()
            coreml.useCPUOnly = false
            coreml.enableOnSubgraphs = false
            coreml.onlyEnableForDevicesWithANE = false
            do {
                try options.appendCoreMLExecutionProvider(with: coreml)
                note = "已请求 CoreML EP"
            } catch {
                note = "CoreML 启用失败：\(error.localizedDescription)"
            }
        case .coreMLANE:
            try options.setIntraOpNumThreads(1)
            let coreml = ORTCoreMLExecutionProviderOptions()
            coreml.useCPUOnly = false
            coreml.enableOnSubgraphs = true
            coreml.onlyEnableForDevicesWithANE = true
            do {
                try options.appendCoreMLExecutionProvider(with: coreml)
                note = "CoreML 仅 ANE + 子图"
            } catch {
                note = "CoreML(ANE) 启用失败：\(error.localizedDescription)"
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
        let tensor = try prepareInputs()

        // 跑两次：第一次包含预热，取较快的一次作为纯推理
        let first = try Self.inferOnce(modelPath: modelURL.path, values: tensor, mode: mode)
        let second = try Self.inferOnce(modelPath: modelURL.path, values: tensor, mode: mode)

        let cls = Self.normalize(second.cls)
        let featureCosine = Self.cosine(cls, cachedExpected ?? [])
        ProbeTrace.mark(.done)

        let detail = """
        \(first.note)
        建 session：\(String(format: "%.0f", first.sessionMs)) / \(String(format: "%.0f", second.sessionMs)) ms
        推理：\(String(format: "%.0f", first.runMs)) / \(String(format: "%.0f", second.runMs)) ms
        特征余弦：\(String(format: "%.8f", featureCosine))
        图像余弦：\(String(format: "%.8f", tensorCheck.cosine))
        """

        return RunSummary(
            mode: mode,
            ok: true,
            note: second.note,
            featureCosine: featureCosine,
            sessionMs: second.sessionMs,
            runMs: min(first.runMs, second.runMs),
            detail: detail
        )
    }
}
