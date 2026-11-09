import Foundation
import onnxruntime_objc

/// DINOv2 编码器（fp16 模型，CPU EP，线程数自动标定）。
///
/// 设计要点（POC 阶段验证过的结论）：
/// - 不用 XNNPACK（iOS 上比纯 CPU 慢 56%）
/// - 不用 CoreML EP（实测没跑在 ANE 上）
/// - session 长驻复用（每次新建会多花 ~80ms）
final class DinoEncoder {
    enum Variant: String {
        case small = "dinov2-small-fp16"
        case base = "dinov2-base-fp16"
    }

    static let dim = 384
    static let baseDim = 768
    /// 查询用的尺度（与 PC/安卓一致）
    static let queryFractions: [Double] = [1.0, 0.85, 0.72, 0.6, 0.5, 0.42, 0.35, 0.29, 0.24, 0.2]
    /// 建库用的尺度
    static let designFractions: [Double] = [1.0, 0.7, 0.5, 0.35, 0.25]

    private let session: ORTSession
    private let inputName: String
    private let outputNames: Set<String>
    private let inputSize: Int
    private let lock = NSLock()

    let variant: Variant
    let loadMs: Double

    init(variant: Variant, inputSize: Int = 224, threads: Int) throws {
        guard let url = DinoEncoder.resolveModelURL(variant: variant) else {
            throw EncoderError.missingModel(variant.rawValue + ".onnx")
        }
        self.variant = variant
        self.inputSize = inputSize

        let started = Date()
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(max(1, threads)))
        let session = try ORTSession(env: env, modelPath: url.path, sessionOptions: options)
        guard let first = try session.inputNames().first else {
            throw EncoderError.badModel("模型没有输入")
        }
        self.session = session
        self.inputName = first
        self.outputNames = Set(try session.outputNames())
        self.loadMs = Date().timeIntervalSince(started) * 1000
    }

    /// 模型查找顺序：图库包的 models/ → App 内嵌
    /// 图库包里的 base 模型最小化 IPA 体积，也避免仓库塞 167MB。
    static func resolveModelURL(variant: Variant) -> URL? {
        let name = variant.rawValue
        if let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) {
            let candidate = support
                .appendingPathComponent("Xiuxun/Gallery/models")
                .appendingPathComponent(name + ".onnx")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return Bundle.main.url(forResource: name, withExtension: "onnx")
    }

    /// 批量编码：每张图各自一份张量，返回每张的 (cls, patches)
    func encode(batch tensors: [[Float]]) throws -> [[ (cls: [Float], patches: [Float]) ]]
    {
        try lock.lock()
        defer { lock.unlock() }

        let count = tensors.count
        guard count > 0 else { return [] }
        let perImage = 3 * inputSize * inputSize
        for tensor in tensors where tensor.count != perImage {
            throw EncoderError.badInput("张量大小 \(tensor.count)，应为 \(perImage)")
        }

        var flat = [Float]()
        flat.reserveCapacity(perImage * count)
        for tensor in tensors { flat.append(contentsOf: tensor) }

        let shape: [NSNumber] = [
            NSNumber(value: count), NSNumber(value: 3),
            NSNumber(value: inputSize), NSNumber(value: inputSize),
        ]
        let data = flat.withUnsafeBufferPointer { Data(buffer: $0) }
        let value = try ORTValue(
            tensorData: NSMutableData(data: data),
            elementType: .float,
            shape: shape
        )
        let outputs = try session.run(
            withInputs: [inputName: value],
            outputNames: outputNames,
            runOptions: nil
        )
        guard let firstOutput = outputs.values.first else {
            throw EncoderError.badModel("模型没有输出")
        }
        let outputData = try firstOutput.tensorData() as Data
        let totalFloats = outputData.count / 4
        let width = variant == .small ? Self.dim : Self.baseDim
        guard totalFloats % (width * count) == 0 else {
            throw EncoderError.badModel(
                "输出 \(totalFloats) 个 float，无法按 \(count) 张 × \(width) 拆分"
            )
        }
        let tokensPerImage = totalFloats / (width * count)

        var result: [[(cls: [Float], patches: [Float])]] = []
        result.reserveCapacity(count)
        outputData.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for imageIndex in 0..<count {
                let imageBase = base.advanced(by: imageIndex * tokensPerImage * width)
                var cls = [Float](repeating: 0, count: width)
                for i in 0..<width { cls[i] = imageBase[i] }
                var patches = [Float]()
                if tokensPerImage > 1 {
                    let patchCount = tokensPerImage - 1
                    patches = [Float](repeating: 0, count: patchCount * width)
                    for token in 1..<tokensPerImage {
                        let source = imageBase.advanced(by: token * width)
                        let target = (token - 1) * width
                        for i in 0..<width { patches[target + i] = source[i] }
                    }
                }
                result.append([(cls: cls, patches: patches)])
            }
        }
        return result
    }

    /// 单张编码
    func encodeOne(_ tensor: [Float]) throws -> (cls: [Float], patches: [Float]) {
        let batched = try encode(batch: [tensor])
        guard let first = batched.first?.first else {
            throw EncoderError.badModel("编码结果为空")
        }
        return first
    }
}

enum EncoderError: LocalizedError {
    case missingModel(String)
    case badModel(String)
    case badInput(String)

    var errorDescription: String? {
        switch self {
        case .missingModel(let name): return "缺少模型 \(name)"
        case .badModel(let reason): return "模型异常：\(reason)"
        case .badInput(let reason): return "输入异常：\(reason)"
        }
    }
}
