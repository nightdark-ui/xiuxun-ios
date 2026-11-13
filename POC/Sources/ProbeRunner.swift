import Foundation
import Combine
import onnxruntime_objc

/// 计算后端 / 配置
enum ComputeMode: String, CaseIterable {
    case cpu1 = "CPU 1线程"
    case cpu4 = "CPU 4线程"
    case cpuAll = "CPU 全核"
    case xnnpackAll = "XNNPACK 全核"
    case coreML = "CoreML"
    case coreMLANE = "CoreML(仅ANE)"
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

/// 设备信息与线程策略（正式版会复用这套逻辑）
enum DeviceInfo {
    static var coreCount: Int { ProcessInfo.processInfo.activeProcessorCount }
    static var memoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1024.0 / 1024.0 / 1024.0
    }
    static var machine: String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.machine", &model, &size, nil, 0)
        return String(cString: model)
    }

    /// 自动标定的结果缓存键
    private static let threadsKey = "perf.bestThreads"

    static var savedBestThreads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: threadsKey)
            return value > 0 ? value : defaultThreads
        }
        set { UserDefaults.standard.set(newValue, forKey: threadsKey) }
    }

    /// 未标定时的保守默认：4 线程（实测 6 核机器上最优）
    static var defaultThreads: Int { max(2, coreCount) }

    static var summary: String {
        String(
            format: "机型 %@ · %d 核 · 内存 %.1f GB · 当前线程 %d",
            machine, coreCount, memoryGB, savedBestThreads
        )
    }
}

final class ProbeRunner: ObservableObject {
    @Published var phase: ProbePhase = .idle
    @Published var phaseText: String = ""
    @Published var summaries: [ComputeMode: RunSummary] = [:]
    @Published var lastCrashStep: String = ProbeTrace.last
    @Published var lastNote: String = ProbeTrace.lastNote
    @Published var autotuneRows: [(threads: Int, ms: Double)] = []
    @Published var autotuneBest: String = ""

    private static let size = 224
    private static let width = 384

    private var cachedTensor: [Float]?
    private var cachedExpected: [Double]?
    private var tensorCheck: (cosine: Double, maxDiff: Double, meanDiff: Double) = (.nan, .nan, .nan)

    // MARK: - 对外入口

    func run(mode: ComputeMode) {
        guard phase != .running else { return }
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
                    mode: mode, ok: false,
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

    /// 自动标定：1…核心数 逐个试，挑最快的线程数并写入 UserDefaults
    func autotune() {
        guard phase != .running else { return }
        phase = .running
        phaseText = "自动标定线程数…"
        autotuneRows = []
        autotuneBest = ""
        ProbeTrace.clear()
        ProbeTrace.clearNote()
        ProbeTrace.mark(.start)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                guard let modelURL = Bundle.main.url(
                    forResource: "dinov2-small-fp16", withExtension: "onnx"
                ) else {
                    throw ProbeError.missingFile("模型没打包进 App")
                }
                let tensor = try self.prepareInputs()

                var rows: [(Int, Double)] = []
                for threads in 1...max(1, DeviceInfo.coreCount) {
                    var best = Double.greatestFiniteMagnitude
                    for _ in 0..<2 {
                        let result = try Self.inferCore(
                            modelPath: modelURL.path,
                            values: tensor,
                            configure: { options in
                                try options.setIntraOpNumThreads(Int32(threads))
                                return "CPU \(threads) 线程"
                            }
                        )
                        best = min(best, result.runMs)
                    }
                    rows.append((threads, best))
                }

                let fastest = rows.min { $0.1 < $1.1 }
                let bestThreads = fastest?.0 ?? DeviceInfo.defaultThreads
                DeviceInfo.savedBestThreads = bestThreads

                DispatchQueue.main.async {
                    self.autotuneRows = rows
                    self.autotuneBest = "最快：\(bestThreads) 线程（\(String(format: "%.0f", fastest?.1 ?? 0)) ms），已保存"
                    self.phase = .done
                    self.phaseText = "标定完成"
                    self.lastCrashStep = ""
                    self.lastNote = ProbeTrace.lastNote
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.phaseText = "标定失败"
                    self.lastCrashStep = ProbeTrace.last
                    self.lastNote = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    // MARK: - 批处理规模测试

    @Published var batchRows: [(size: Int, ms: Double, perImage: Double)] = []
    @Published var batchBest: String = ""

    /// 测试 batch = 1/4/10/20 时的吞吐，找出每张图最划算的批大小
    func batchTest() {
        guard phase != .running else { return }
        phase = .running
        phaseText = "批处理测试…"
        batchRows = []
        batchBest = ""
        ProbeTrace.clear()
        ProbeTrace.mark(.start)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                guard let modelURL = Bundle.main.url(
                    forResource: "dinov2-small-fp16", withExtension: "onnx"
                ) else {
                    throw ProbeError.missingFile("模型没打包进 App")
                }
                let tensor = try self.prepareInputs()
                let threads = Int32(DeviceInfo.savedBestThreads)

                var rows: [(Int, Double, Double)] = []
                for batch in [1, 4, 10, 20] {
                    let ms = try Self.runBatch(
                        modelPath: modelURL.path,
                        single: tensor,
                        batch: batch,
                        threads: threads
                    )
                    rows.append((batch, ms, ms / Double(batch)))
                }
                let best = rows.min { $0.2 < $1.2 }
                DispatchQueue.main.async {
                    self.batchRows = rows.map { (size: $0.0, ms: $0.1, perImage: $0.2) }
                    self.batchBest = best.map {
                        String(format: "每张最省：批 %d（每张 %.0f ms）", $0.0, $0.2)
                    } ?? ""
                    self.phase = .done
                    self.phaseText = "批处理测试完成"
                    self.lastCrashStep = ""
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.phaseText = "批处理测试失败"
                    self.lastCrashStep = ProbeTrace.last
                    self.lastNote = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
            }
        }
    }

    private static func runBatch(
        modelPath: String,
        single: [Float],
        batch: Int,
        threads: Int32
    ) throws -> Double {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(threads)
        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        guard let inputName = try session.inputNames().first else {
            throw ProbeError.badOutput("模型没有输入")
        }
        let outputNames = Set(try session.outputNames())

        var values = [Float]()
        values.reserveCapacity(single.count * batch)
        for _ in 0..<batch { values.append(contentsOf: single) }

        let shape: [NSNumber] = [
            NSNumber(value: batch), NSNumber(value: 3),
            NSNumber(value: size), NSNumber(value: size),
        ]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let tensor = try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .float,
            shape: shape
        )
        // 预热一次
        _ = try session.run(withInputs: [inputName: tensor], outputNames: outputNames, runOptions: nil)
        let started = Date()
        _ = try session.run(withInputs: [inputName: tensor], outputNames: outputNames, runOptions: nil)
        return Date().timeIntervalSince(started) * 1000
    }

    // MARK: - 图像链路（只算一次）

    private func prepareInputs() throws -> [Float] {
        if let ours = cachedTensor, cachedExpected != nil { return ours }
        guard let imageURL = Bundle.main.url(forResource: "probe_image", withExtension: "jpg") else {
            throw ProbeError.missingFile("ȱ probe_image.jpg")
        }
        guard let refURL = Bundle.main.url(forResource: "probe_input", withExtension: "bin") else {
            throw ProbeError.missingFile("ȱ probe_input.bin")
        }
        guard let expectedURL = Bundle.main.url(forResource: "probe_expected", withExtension: "txt") else {
            throw ProbeError.missingFile("ȱ probe_expected.txt")
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

        ProbeTrace.note(
            "图像余弦 \(String(format: "%.8f", tensorCheck.cosine))" +
            "；\(DeviceInfo.summary)"
        )

        cachedTensor = ours
        cachedExpected = expected
        return ours
    }

    // MARK: - 推理核心

    private struct InferResult {
        var cls: [Double]
        var sessionMs: Double
        var runMs: Double
        var note: String
    }

    /// 通用推理：configure 里配置 session options，同时返回说明文字
    private static func inferCore(
        modelPath: String,
        values: [Float],
        configure: (ORTSessionOptions) throws -> String
    ) throws -> InferResult {
        let sessionStarted = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        let note = try configure(options)

        let session = try ORTSession(env: env, modelPath: modelPath, sessionOptions: options)
        let inputNames = try session.inputNames()
        guard let inputName = inputNames.first else { throw ProbeError.badOutput("模型没有输入") }
        let outputNames = Set(try session.outputNames())
        let sessionMs = Date().timeIntervalSince(sessionStarted) * 1000

        let runStarted = Date()
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        let shape: [NSNumber] = [
            NSNumber(value: 1), NSNumber(value: 3),
            NSNumber(value: size), NSNumber(value: size),
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
        return InferResult(cls: cls, sessionMs: sessionMs, runMs: runMs, note: note)
    }

    private static func inferOnce(
        modelPath: String,
        values: [Float],
        mode: ComputeMode
    ) throws -> InferResult {
        try inferCore(modelPath: modelPath, values: values) { options in
            switch mode {
            case .cpu1:
                try options.setIntraOpNumThreads(1)
                return "1 线程"
            case .cpu4:
                try options.setIntraOpNumThreads(4)
                return "4 线程"
            case .cpuAll:
                let cores = DeviceInfo.coreCount
                try options.setIntraOpNumThreads(Int32(cores))
                return "CPU \(cores) 线程（全核）"
            case .xnnpackAll:
                try options.setIntraOpNumThreads(1)
                let threads = DeviceInfo.coreCount
                let xnn = ORTXnnpackExecutionProviderOptions()
                xnn.intra_op_num_threads = Int32(threads)
                try options.appendXnnpackExecutionProvider(with: xnn)
                return "XNNPACK \(threads) 线程"
            case .coreML:
                try options.setIntraOpNumThreads(1)
                let coreml = ORTCoreMLExecutionProviderOptions()
                coreml.useCPUOnly = false
                coreml.enableOnSubgraphs = false
                coreml.onlyEnableForDevicesWithANE = false
                try options.appendCoreMLExecutionProvider(with: coreml)
                return "已请求 CoreML EP"
            case .coreMLANE:
                try options.setIntraOpNumThreads(1)
                let coreml = ORTCoreMLExecutionProviderOptions()
                coreml.useCPUOnly = false
                coreml.enableOnSubgraphs = true
                coreml.onlyEnableForDevicesWithANE = true
                try options.appendCoreMLExecutionProvider(with: coreml)
                return "CoreML 仅 ANE + 子图"
            }
        }
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

    /// 与 PC 完全一致：只用 FP16 模型（不使用 INT8）
    private static func modelName(for mode: ComputeMode) -> String {
        "dinov2-small-fp16"
    }

    private func runSync(mode: ComputeMode) throws -> RunSummary {
        guard let modelURL = Bundle.main.url(
            forResource: Self.modelName(for: mode), withExtension: "onnx"
        ) else {
            throw ProbeError.missingFile("缺少模型：\(Self.modelName(for: mode)).onnx")
        }
        let tensor = try prepareInputs()

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
