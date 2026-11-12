import Foundation
import CryptoKit

/// 查询特征（与 PC/安卓同结构）
struct QueryFeatures {
    /// 每个旋转角度 × 每个尺度的一行 CLS（384 维）
    var clsRows: [[Float]]
    /// 每个旋转角度 × 9 块的 tile 特征（384 维）
    var tileRows: [[Float]]
    /// 第一个尺度（fraction 1.0）的 patch token，每行 384，供 dense 匹配
    var patchRows: [[Float]] = []
    var label: String
    var fromCache: Bool = false
}

/// 搜索选项
struct SearchOptions {
    var rotationEnabled = true
    var mirrorEnabled = false        // 镜像快速模式（默认关）
    var fastMode = false             // 快速模式：4 角度
    var deepReview = false           // 深度复核：候选更宽 + base 336
    var resultCount = 30
    var baseInputSize = 336
    var sensitivity = 1.0
    var selectedLibraries: Set<String> = []
    var autoCrop: Bool = true
    /// 循环花型增强（实验，默认关）
    var allowRepeat: Bool = false
    var localFirst: Bool = false
    /// 0 精准 / 1 均衡 / 2 宽松
    var strictness: Int = 1
    /// 诊断：指定款号，搜索后在备注里输出它的排名与分数
    var diagnosticCode: String = ""
    var codeFrom: String = ""
    var codeTo: String = ""
}

/// 查询编码器：CLS（10 尺度）+ tile（3×3），带磁盘缓存
final class QueryEncoder {
    private let small: DinoEncoder
    private var baseEncoders: [Int: DinoEncoder] = [:]
    private let cacheDir: URL
    private static let dim = 384
    private let threads: Int

    init(threads: Int) throws {
        self.threads = threads
        small = try DinoEncoder(variant: .small, inputSize: 224, threads: threads)
        let support = (try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = support.appendingPathComponent("XiuxunQuery", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    var smallLoadMs: Double { small.loadMs }

    /// 内存查询缓存（含 patchRows，App 重启即清空，不落盘）
    private static var memoryCache: [String: QueryFeatures] = [:]
    private static var memoryOrder: [String] = []
    private static let memoryLock = NSLock()

    private static func memoryGet(_ key: String) -> QueryFeatures? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memoryCache[key]
    }

    private static func memoryPut(_ key: String, _ features: QueryFeatures) {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        memoryCache[key] = features
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > 2, let oldest = memoryOrder.first {
            memoryOrder.removeFirst()
            memoryCache.removeValue(forKey: oldest)
        }
    }

    /// 编码一张查询图（内部按 8 旋转 × 10 尺度 + 9 tile 批量推理）
    func encode(
        enhancedGray image: PilImaging.GrayImage,
        options: SearchOptions,
        originalData: Data
    ) throws -> QueryFeatures {
        let key = Self.cacheKey(
            data: originalData,
            rotation: options.rotationEnabled,
            mirror: options.mirrorEnabled,
            fast: options.fastMode
        )
        if let cached = Self.memoryGet(key) { return cached }

        var base = image
        if options.autoCrop {
            base = ImageOps.autoCropSubject(image)
        }

        let angles: [Int] = {
            if !options.rotationEnabled { return [0] }
            return options.fastMode ? [0, 90, 180, 270] : [0, 45, 90, 135, 180, 225, 270, 315]
        }()

        var variants: [(label: String, image: PilImaging.GrayImage)] = []
        for angle in angles {
            variants.append(("rot\(angle)", ImageOps.rotate(base, degrees: angle)))
        }
        if options.mirrorEnabled {
            let mirrored = ImageOps.mirror(base)
            for angle in angles {
                variants.append(("mir\(angle)", ImageOps.rotate(mirrored, degrees: angle)))
            }
        }
        // 边条变体：上下左右四条 34% 的条带（PC 的 border strip 思路）
        var borderStrips: [(String, PilImaging.GrayImage)] = []
        let stripFraction = 0.34
        borderStrips.append(("strip-top", ImageOps.cropBand(base, fraction: stripFraction, side: .top)))
        borderStrips.append(("strip-bottom", ImageOps.cropBand(base, fraction: stripFraction, side: .bottom)))
        borderStrips.append(("strip-left", ImageOps.cropBand(base, fraction: stripFraction, side: .left)))
        borderStrips.append(("strip-right", ImageOps.cropBand(base, fraction: stripFraction, side: .right)))

        // 循环花型增强：追加若干"重复单元"变体（只提供 CLS）
        var repeatVariants: [PilImaging.GrayImage] = []
        if options.allowRepeat {
            repeatVariants = RepeatVariants.variants(base)
        }

        var clsRows: [[Float]] = []
        var tileRows: [[Float]] = []
        var patchRows: [[Float]] = []

        for variant in variants {
            // 10 个尺度一批
            let fractionTensors = DinoEncoder.queryFractions.map {
                ImageOps.prepareTensor(variant.image, fraction: $0, size: 224)
            }
            let encoded = try small.encode(batch: fractionTensors)
            for (index, item) in encoded.enumerated() {
                guard let first = item.first else { continue }
                clsRows.append(normalize(first.cls))
                // 只保留第一个尺度（fraction 1.0）的 patch，用于 dense 匹配
                if index == 0, !first.patches.isEmpty {
                    var rows: [[Float]] = []
                    let rowCount = first.patches.count / 384
                    rows.reserveCapacity(rowCount)
                    for r in 0..<rowCount {
                        let start = r * 384
                        rows.append(normalize(Array(first.patches[start..<(start + 384)])))
                    }
                    patchRows.append(contentsOf: rows)
                }
            }

            // PC 的 9 个 tile（位置表 × 0.34）
            let tileTensors = ImageOps.prepareTiles(variant.image, size: 224)
            if !tileTensors.isEmpty {
                let tileEncoded = try small.encode(batch: tileTensors)
                for item in tileEncoded {
                    if let first = item.first {
                        tileRows.append(normalize(first.cls))
                    }
                }
            }
        }

        for (_, strip) in borderStrips {
            let tensors = DinoEncoder.queryFractions.map {
                ImageOps.prepareTensor(strip, fraction: $0, size: 224)
            }
            if let encoded = try? small.encode(batch: tensors) {
                for item in encoded {
                    if let first = item.first {
                        clsRows.append(normalize(first.cls))
                    }
                }
            }
        }

        for variant in repeatVariants {
            let tensors = DinoEncoder.queryFractions.map {
                ImageOps.prepareTensor(variant, fraction: $0, size: 224)
            }
            if let encoded = try? small.encode(batch: tensors) {
                for item in encoded {
                    if let first = item.first {
                        clsRows.append(normalize(first.cls))
                    }
                }
            }
        }

        var features = QueryFeatures(clsRows: clsRows, tileRows: tileRows, label: "查询特征")
        features.patchRows = patchRows
        saveCache(key: key, features: features)
        Self.memoryPut(key, features)
        return features
    }

    /// 给候选设计图算 patch token（PC 的 dense 就是实时算这个）
    func designPatches(
        _ image: PilImaging.GrayImage,
        fraction: Double = 1.0
    ) throws -> [[Float]] {
        let tensor = ImageOps.prepareTensor(image, fraction: fraction, size: 224)
        let encoded = try small.encodeOne(tensor)
        var rows: [[Float]] = []
        let rowCount = encoded.patches.count / 384
        rows.reserveCapacity(rowCount)
        for r in 0..<rowCount {
            let start = r * 384
            rows.append(normalize(Array(encoded.patches[start..<(start + 384)])))
        }
        return rows
    }

    /// base 重排用的查询向量（768 维）。size 决定 224（普通）还是 336（深度复核）。
    func encodeBase(
        enhancedGray image: PilImaging.GrayImage,
        size: Int
    ) throws -> [Float] {
        let encoder = try baseEncoder(size: size)
        let tensor = ImageOps.prepareTensor(image, fraction: 1.0, size: size)
        let encoded = try encoder.encode(batch: [tensor])
        guard let first = encoded.first?.first else { return [] }
        return normalize(first.cls)
    }

    /// base 编码器按尺寸复用（224 与 336 各一个，避免每次重建 session）
    private func baseEncoder(size: Int) throws -> DinoEncoder {
        if let existing = baseEncoders[size] { return existing }
        let encoder = try DinoEncoder(variant: .base, inputSize: size, threads: threads)
        baseEncoders[size] = encoder
        return encoder
    }

    // MARK: - 工具

    private func normalize(_ values: [Float]) -> [Float] {
        var result = values
        var norm: Double = 0
        for v in result { norm += Double(v) * Double(v) }
        norm = sqrt(norm)
        if norm > 1e-9 {
            for i in 0..<result.count { result[i] = Float(Double(result[i]) / norm) }
        }
        return result
    }

    private static func cacheKey(data: Data, rotation: Bool, mirror: Bool, fast: Bool) -> String {
        var hasher = SHA256()
        hasher.update(data: data)
        let flags = "\(rotation)-\(mirror)-\(fast)"
        hasher.update(data: Data(flags.utf8))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func cacheURL(_ key: String) -> URL {
        cacheDir.appendingPathComponent("\(key).qfc")
    }

    private func saveCache(key: String, features: QueryFeatures) {
        var blob = Data()
        var clsCount = UInt32(features.clsRows.count)
        var tileCount = UInt32(features.tileRows.count)
        withUnsafeBytes(of: &clsCount) { blob.append(contentsOf: $0) }
        withUnsafeBytes(of: &tileCount) { blob.append(contentsOf: $0) }
        for row in features.clsRows {
            row.withUnsafeBufferPointer { buffer in
                blob.append(Data(buffer: buffer))
            }
        }
        for row in features.tileRows {
            row.withUnsafeBufferPointer { buffer in
                blob.append(Data(buffer: buffer))
            }
        }
        try? blob.write(to: cacheURL(key), options: .atomic)
    }

    private func loadCache(key: String) -> QueryFeatures? {
        guard let blob = try? Data(contentsOf: cacheURL(key)), blob.count > 8 else { return nil }
        return blob.withUnsafeBytes { raw -> QueryFeatures? in
            let base = raw.baseAddress!
            let clsCount = Int(base.assumingMemoryBound(to: UInt32.self).pointee)
            let tileCount = Int(base.advanced(by: 4).assumingMemoryBound(to: UInt32.self).pointee)
            let floatsOffset = 8
            let needed = floatsOffset + (clsCount + tileCount) * Self.dim * 4
            guard blob.count >= needed, clsCount > 0 else { return nil }
            let floats = base.advanced(by: floatsOffset).assumingMemoryBound(to: Float.self)
            var clsRows: [[Float]] = []
            var tileRows: [[Float]] = []
            for index in 0..<clsCount {
                let start = index * Self.dim
                clsRows.append(Array(UnsafeBufferPointer(start: floats + start, count: Self.dim)))
            }
            for index in 0..<tileCount {
                let start = (clsCount + index) * Self.dim
                tileRows.append(Array(UnsafeBufferPointer(start: floats + start, count: Self.dim)))
            }
            return QueryFeatures(clsRows: clsRows, tileRows: tileRows, label: "查询缓存", fromCache: true)
        }
    }
}
