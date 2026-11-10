import Foundation

/// 读取 heavy.bin 里候选款的重特征（tiles5 + 全局描述子），只读需要的部分。
///
/// 安卓/PC 的记录布局（小端 float32）：
///   tiles5[25 × 384]
///   edge[6400]                  （80×80 边缘图）
///   fm[256]  lbp[20]  ori[14]  radial[28]  hu[7]  stats[4]
///   siftCount:int32
///   kp[siftCount × 5]  desc[siftCount × 128]   ← iOS 暂不读
final class HeavyStore {
    static let tileRows = 25
    static let dim = 384
    static let edgeSize = 6400
    static let fmCount = 256
    static let lbpCount = 20
    static let oriCount = 14
    static let radialCount = 28
    static let huCount = 7
    static let statsCount = 4

    /// 固定头部（不含 SIFT）
    static let headerFloats = tileRows * dim + edgeSize
        + fmCount + lbpCount + oriCount + radialCount + huCount + statsCount

    struct DesignFeatures {
        var tiles5: [Float]
        var edge: [Float]
        var fm: [Float]
        var lbp: [Float]
        var ori: [Float]
        var radial: [Float]
        var hu: [Float]
        var stats: [Float]
    }

    private let data: Data
    private var cache: [Int: DesignFeatures] = [:]
    private let lock = NSLock()

    init?(root: URL) {
        let url = root.appendingPathComponent("heavy.bin")
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        data = mapped
    }

    var byteSize: Int { data.count }

    /// 读取某个设计的重特征（按 heavyOffset）
    func features(at offset: Int64) -> DesignFeatures? {
        let key = Int(offset)
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let headerBytes = Self.headerFloats * 4
        guard offset >= 0, Int(offset) + headerBytes <= data.count else { return nil }

        var result = DesignFeatures(
            tiles5: [], edge: [], fm: [], lbp: [], ori: [], radial: [], hu: [], stats: []
        )
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let floats = base.advanced(by: Int(offset)).assumingMemoryBound(to: Float.self)
            var cursor = 0
            func take(_ count: Int) -> [Float] {
                let slice = Array(UnsafeBufferPointer(start: floats + cursor, count: count))
                cursor += count
                return slice
            }
            result.tiles5 = take(Self.tileRows * Self.dim)
            result.edge = take(Self.edgeSize)
            result.fm = take(Self.fmCount)
            result.lbp = take(Self.lbpCount)
            result.ori = take(Self.oriCount)
            result.radial = take(Self.radialCount)
            result.hu = take(Self.huCount)
            result.stats = take(Self.statsCount)
        }

        lock.lock()
        if cache.count > 64 { cache.removeAll() }
        cache[key] = result
        lock.unlock()
        return result
    }
}

/// PC 的 dense 局部匹配（`ai_features.dense_similarity` 的 Swift 版）
enum DenseMatch {
    /// - Parameters:
    ///   - queryPatches: 查询图的 patch token（每行 384，已 L2 归一化）
    ///   - designTiles: 图库款的 tiles5（25 行 × 384，已归一化）
    /// - Returns: 0…1，`0.70 × max_mean + 0.30 × mutual_mean`
    static func similarity(queryPatches: [[Float]], designTiles: [Float]) -> Double {
        let queryCount = queryPatches.count
        let designCount = designTiles.count / 384
        guard queryCount > 0, designCount > 0 else { return 0 }

        // bestDesign[i] = argmax_j cosine(q_i, d_j)，bestValues[i] = 该最大相似度
        var bestDesign = [Int](repeating: 0, count: queryCount)
        var bestValues = [Double](repeating: 0, count: queryCount)
        // bestQuery[j] = argmax_i cosine(q_i, d_j)
        var bestQuery = [Int](repeating: -1, count: designCount)
        var bestQueryValue = [Double](repeating: -1, count: designCount)

        for i in 0..<queryCount {
            let q = queryPatches[i]
            for j in 0..<designCount {
                let cosine = dot(q, designTiles, j * 384)
                if cosine > bestValues[i] {
                    bestValues[i] = cosine
                    bestDesign[i] = j
                }
                if cosine > bestQueryValue[j] {
                    bestQueryValue[j] = cosine
                    bestQuery[j] = i
                }
            }
        }

        var mutualSum = 0.0
        var mutualCount = 0
        for i in 0..<queryCount where bestQuery[bestDesign[i]] == i {
            mutualSum += bestValues[i]
            mutualCount += 1
        }
        let mutualMean = mutualCount > 0 ? mutualSum / Double(mutualCount) : 0
        let maxMean = bestValues.reduce(0, +) / Double(queryCount)
        return min(1.0, max(0.0, 0.70 * maxMean + 0.30 * mutualMean))
    }

    static let DesignTileRows = 25

    private static func dot(_ query: [Float], _ tiles: [Float], _ offset: Int) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        let count = min(384, query.count)
        for i in 0..<count {
            let x = Double(query[i])
            let y = Double(tiles[offset + i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }
}
