import Foundation
import Combine
import onnxruntime_objc

/// 综合探针 v4：
///   A. 图像链路：JPEG → 灰度 → 裁切 → BICUBIC 224 → 归一化，与 PC 张量比对
///   B. 模型链路：先用 PC 参考张量跑一遍，再用自算张量跑（A/B）
///   C. 速度：每次推理都重新建 session（与 v1 相同的调用方式，最保守）
///
/// v3 用了「静态缓存 session + NSLock + 嵌套函数」，结果 session.run 崩溃；
/// v1 是「每次新建 session」且成功，所以这里退回 v1 的调用方式。
enum ProbePhase: String {
    case idle = "未运行"
    case running = "运行中…"
    case done = "完成"
    case failed = "失败"
}

struct ProbeReport {
    let tensorCosine: Double
    let tensorMaxDiff: Double
    let tensorMeanDiff: Double
    let refCosine: Double
    let featureCosine: Double
    let featureMaxDiff: Double
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
    @Published var lastCrashStep: String = ProbeTrace.last
    @Published var lastNote: String = ProbeTrace.lastNote

    private static let size = 224
    private static let width = 384

    func run() {
        phase = .running
        log = ""
        lastCrashStep = ""
        lastNote = ""
        ProbeTrace.clear()
        ProbeTrace.clearNote()
        ProbeTrace.mark(.start)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let report = try ProbeRunner.runSync()
                DispatchQueue.main.async {
                    self.tensorCosine = report.tensorCosine
                    self.tensorMaxDiff = report.tensorMaxDiff
                    self.featureCosine = report.featureCosine
                    self.runMs = report.runMs.min() ?? .nan
                    self.log = report.log
                    self.phase = .done
                    self.lastCrashStep = ""
                    self.lastNote = ProbeTrace.lastNote
                    ProbeTrace.clear()
                }
            } catch {
                DispatchQueue.main.async {
                    self.phase = .failed
                    self.lastCrashStep = ProbeTrace.last
                    self.lastNote = ProbeTrace.lastNote
                    self.log = "❌ 失败于「\(ProbeTrace.last)」：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 最保守的一次推理：新建 env + session，跑一次，取 CLS 前 384 维。
    private static func inferOnce(
        modelPath: String,
        values: [Float]
    ) throws -> (cls: [Double], sessionMs: Double, runMs: Double) {
        let sessionStarted = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
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
        return (cls, sessionMs, runMs)
    }

    private static func normalize(_ values: [Double]) -> [Double] {
        var result = values
        var norm = 0.0
        for v in result { norm += v * v }
        norm = sqrt(norm)
        if norm > 1e-9 { for i in 0..<result.count { result[i] /= norm } }
        return result
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> (cosine: Double, maxDiff: Double) {
        var dot = 0.0, na = 0.0, nb = 0.0, mx = 0.0
        let limit = min(a.count, b.count)
        for i in 0..<limit {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
            mx = max(mx, abs(a[i] - b[i]))
        }
        return (dot / (sqrt(na) * sqrt(nb)), mx)
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
        guard let modelURL = Bundle.main.url(forResource: "dinov2-small-fp16", withExtension: "onnx") else {
            throw ProbeError.missingFile("模型没打包进 App")
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
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for i in 0..<ours.count { reference[i] = base[i] }
        }

        var tensorCosine = 0.0
        var tensorMaxDiff = 0.0
        var tensorMeanDiff = 0.0
        var absSum = 0.0
        var dot = 0.0, normA = 0.0, normB = 0.0
        for i in 0..<ours.count {
            let a = Double(ours[i])
            let b = Double(reference[i])
            dot += a * b
            normA += a * a
            normB += b * b
            let d = abs(a - b)
            tensorMaxDiff = max(tensorMaxDiff, d)
            absSum += d
        }
        tensorCosine = dot / (sqrt(normA) * sqrt(normB))
        tensorMeanDiff = absSum / Double(ours.count)

        // 张量体检（崩溃后可读）
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

        // ---------- B1. 参考张量（v1 已验证能跑通的那份数据）----------
        ProbeTrace.mark(.runReference)
        let refRun = try inferOnce(modelPath: modelURL.path, values: reference)
        let refCls = normalize(refRun.cls)
        let refResult = cosine(refCls, expected)

        // ---------- B2. 自算张量 ----------
        ProbeTrace.mark(.runOurs)
        let ourRun = try inferOnce(modelPath: modelURL.path, values: ours)
        let ourCls = normalize(ourRun.cls)
        let featureResult = cosine(ourCls, expected)

        // ---------- C. 速度（再跑两次，含 session 创建）----------
        var sessionTimings: [Double] = [ourRun.sessionMs]
        var runTimings: [Double] = [ourRun.runMs]
        for _ in 0..<2 {
            let result = try inferOnce(modelPath: modelURL.path, values: ours)
            sessionTimings.append(result.sessionMs)
            runTimings.append(result.runMs)
        }

        ProbeTrace.mark(.done)

        let tensorVerdict = tensorCosine >= 0.9999
            ? "✅ 图像链路一致"
            : (tensorCosine >= 0.999 ? "⚠️ 接近（约 1 级灰度差）" : "❌ 不一致")
        let featureVerdict = featureResult.cosine >= 0.999
            ? "✅ 特征一致"
            : (featureResult.cosine >= 0.99 ? "⚠️ 特征接近" : "❌ 特征不一致")

        let sessionText = sessionTimings.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        let runText = runTimings.map { String(format: "%.0f", $0) }.joined(separator: " / ")
        let log = """
        【A. 图像链路】
          原图：\(prepared.gray.width)×\(prepared.gray.height)
          张量余弦：\(String(format: "%.8f", tensorCosine))
          最大单项差：\(String(format: "%.6f", tensorMaxDiff))
          平均单项差：\(String(format: "%.6f", tensorMeanDiff))
          \(tensorVerdict)

        【B. 模型链路】
          参考张量→特征余弦：\(String(format: "%.8f", refResult.cosine))
          自算张量→特征余弦：\(String(format: "%.8f", featureResult.cosine))
          最大单项差：\(String(format: "%.8f", featureResult.maxDiff))
          \(featureVerdict)

        【C. 速度】
          建 session：\(sessionText) ms
          纯推理：\(runText) ms
        """
        return ProbeReport(
            tensorCosine: tensorCosine,
            tensorMaxDiff: tensorMaxDiff,
            tensorMeanDiff: tensorMeanDiff,
            refCosine: refResult.cosine,
            featureCosine: featureResult.cosine,
            featureMaxDiff: featureResult.maxDiff,
            runMs: runTimings,
            log: log
        )
    }
}
