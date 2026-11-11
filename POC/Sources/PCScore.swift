import Foundation
import UIKit

/// PC 的 compare_global + edge_correlation + final_score 的 Swift 移植
///
/// PC 公式（matching.py）：
///   shape   = 0.72*fm + 0.12*hu + 0.16*stats
///   texture = 0.72*lbp + 0.16*ori + 0.12*radial
///   old     = 0.46*local + 0.20*edge + 0.14*fm + 0.10*lbp + 0.04*ori + 0.03*radial + 0.03*shape
///   aiComp  = clip((ai - 0.45) / 0.40, 0, 1)
///   score   = 0.75*aiComp + 0.25*old
enum PCScore {

    struct GlobalSims {
        var fm: Double
        var lbp: Double
        var ori: Double
        var radial: Double
        var hu: Double
        var stats: Double
        var shape: Double
        var texture: Double
    }

    // MARK: - 查询侧描述子

    struct QueryDescriptor {
        var edge: [Float]        // 80×80
        var fm: [Float]          // 256
        var lbp: [Float]         // 20
        var ori: [Float]         // 14
        var radial: [Float]      // 28
        var hu: [Float]          // 7
        var stats: [Float]       // 4
    }

    static func describe(_ image: PilImaging.GrayImage) -> QueryDescriptor {
        let edge = StructureScore.edgeMap(image)
        return QueryDescriptor(
            edge: edge,
            fm: FourierMellin.descriptor(edge: edge, side: StructureScore.edgeSide),
            lbp: lbpHistogram(image),
            ori: orientationHistogram(edge, side: StructureScore.edgeSide),
            radial: radialHistogram(edge, side: StructureScore.edgeSide),
            hu: StructureScore.huMoments(edge, side: StructureScore.edgeSide),
            stats: StructureScore.simpleStats(image)
        )
    }

    /// 20 桶 LBP 直方图（归一化）
    static func lbpHistogram(_ image: PilImaging.GrayImage) -> [Float] {
        var bins = [Float](repeating: 0, count: 20)
        let w = image.width
        let h = image.height
        guard w > 2, h > 2 else { return bins }
        var total: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let center = image.pixels[y * w + x]
                var code: UInt8 = 0
                let neighbors = [
                    (-1, -1), (0, -1), (1, -1), (1, 0),
                    (1, 1), (0, 1), (-1, 1), (-1, 0)
                ]
                for (bit, offset) in neighbors.enumerated() {
                    let value = image.pixels[(y + offset.1) * w + (x + offset.0)]
                    if value >= center { code |= (1 << UInt8(bit)) }
                }
                // 统一模式压缩到 0…19
                let ones = code.nonzeroBitCount
                bins[ones == 0 || ones == 8 ? 0 : min(19, Int(ones) + 1)] += 1
                total += 1
            }
        }
        if total > 0 {
            for i in 0..<bins.count { bins[i] /= total }
        }
        return bins
    }

    /// 14 桶梯度方向直方图
    static func orientationHistogram(_ edge: [Float], side: Int) -> [Float] {
        var bins = [Float](repeating: 0, count: 14)
        var total: Float = 0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let gx = edge[y * side + x + 1] - edge[y * side + x - 1]
                let gy = edge[(y + 1) * side + x] - edge[(y - 1) * side + x]
                let magnitude = (gx * gx + gy * gy).squareRoot()
                guard magnitude > 0.01 else { continue }
                var angle = atan2(Double(gy), Double(gx))
                if angle < 0 { angle += Double.pi }
                let bin = min(13, Int(angle / Double.pi * 14.0))
                bins[bin] += magnitude
                total += magnitude
            }
        }
        if total > 0 {
            for i in 0..<bins.count { bins[i] /= total }
        }
        return bins
    }

    /// 28 桶径向能量分布
    static func radialHistogram(_ edge: [Float], side: Int) -> [Float] {
        var bins = [Float](repeating: 0, count: 28)
        let center = Double(side) / 2.0
        var total: Float = 0
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let radius = (dx * dx + dy * dy).squareRoot()
                let bin = min(27, Int(radius / center * 28.0))
                bins[bin] += edge[y * side + x]
                total += edge[y * side + x]
            }
        }
        if total > 0 {
            for i in 0..<bins.count { bins[i] /= total }
        }
        return bins
    }

    // MARK: - 相似度

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 1e-9, nb > 1e-9 else { return 0 }
        return max(0, dot / (na.squareRoot() * nb.squareRoot()))
    }

    /// 直方图交集
    static func histogramIntersection(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<count { sum += Double(min(a[i], b[i])) }
        return min(1.0, sum)
    }

    static func compareGlobal(query: QueryDescriptor, design: HeavyStore.DesignFeatures) -> GlobalSims {
        let fm = cosine(query.fm, design.fm)
        let lbp = histogramIntersection(query.lbp, design.lbp)
        let ori = cosine(query.ori, design.ori)
        let radial = cosine(query.radial, design.radial)
        let hu = StructureScore.huSimilarity(query.hu, design.hu)
        let stats = StructureScore.statsSimilarity(query.stats, design.stats)
        let shape = min(1, max(0, 0.72 * fm + 0.12 * hu + 0.16 * stats))
        let texture = min(1, max(0, 0.72 * lbp + 0.16 * ori + 0.12 * radial))
        return GlobalSims(
            fm: fm, lbp: lbp, ori: ori, radial: radial,
            hu: hu, stats: stats, shape: shape, texture: texture
        )
    }

    /// 任意角度旋转边缘图（双线性，80×80 足够快）
    static func rotateEdge(_ edge: [Float], side: Int, degrees: Double) -> [Float] {
        let turns = Int((degrees / 90.0).rounded()) % 4
        if abs(degrees.truncatingRemainder(dividingBy: 90)) < 0.001 {
            return rotate90(edge, side: side, angle: turns * 90)
        }
        let radians = degrees * Double.pi / 180.0
        let cosA = cos(radians)
        let sinA = sin(radians)
        let center = Double(side) / 2.0
        var output = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) - center
                let dy = Double(y) - center
                let sx = center + dx * cosA + dy * sinA
                let sy = center - dx * sinA + dy * cosA
                if sx < 0 || sy < 0 || sx >= Double(side - 1) || sy >= Double(side - 1) { continue }
                let x0 = Int(sx), y0 = Int(sy)
                let fx = Float(sx - Double(x0)), fy = Float(sy - Double(y0))
                let v00 = edge[y0 * side + x0]
                let v01 = edge[y0 * side + x0 + 1]
                let v10 = edge[(y0 + 1) * side + x0]
                let v11 = edge[(y0 + 1) * side + x0 + 1]
                let top = v00 * (1 - fx) + v01 * fx
                let bottom = v10 * (1 - fx) + v11 * fx
                output[y * side + x] = top * (1 - fy) + bottom * fy
            }
        }
        return output
    }

    /// 最佳旋转下的全局相似度 + 边缘相关（PC: step=15，共 24 档）
    static func bestRotation(
        query: QueryDescriptor,
        design: HeavyStore.DesignFeatures,
        allowRotation: Bool
    ) -> (sims: GlobalSims, edge: Double) {
        let side = StructureScore.edgeSide
        let angles: [Double] = allowRotation
            ? stride(from: 0.0, to: 360.0, by: 15.0).map { $0 }
            : [0.0]

        var bestSims: GlobalSims?
        var bestEdge = 0.0

        for angle in angles {
            let rotated = angle == 0 ? query.edge : rotateEdge(query.edge, side: side, degrees: angle)
            let edgeScore = StructureScore.edgeCorrelation(rotated, design.edge)
            if edgeScore > bestEdge { bestEdge = edgeScore }

            // 旋转敏感的 ori/radial 每 45° 重算一次（PC 每个变体都算）
            if Int(angle.truncatingRemainder(dividingBy: 45)) == 0 {
                let ori = cosine(orientationHistogram(rotated, side: side), design.ori)
                let radial = cosine(radialHistogram(rotated, side: side), design.radial)
                let fm = cosine(query.fm, design.fm)
                let lbp = histogramIntersection(query.lbp, design.lbp)
                let hu = StructureScore.huSimilarity(query.hu, design.hu)
                let stats = StructureScore.statsSimilarity(query.stats, design.stats)
                let shape = min(1, max(0, 0.72 * fm + 0.12 * hu + 0.16 * stats))
                let texture = min(1, max(0, 0.72 * lbp + 0.16 * ori + 0.12 * radial))
                let sims = GlobalSims(
                    fm: fm, lbp: lbp, ori: ori, radial: radial,
                    hu: hu, stats: stats, shape: shape, texture: texture
                )
                if bestSims == nil || sims.texture > bestSims!.texture {
                    bestSims = sims
                }
            }
        }
        let final = bestSims ?? compareGlobal(query: query, design: design)
        return (final, bestEdge)
    }

    /// 仅支持 90 的倍数（足够覆盖整档旋转）
    private static func rotate90(_ data: [Float], side: Int, angle: Int) -> [Float] {
        let turns = ((angle / 90) % 4 + 4) % 4
        if turns == 0 { return data }
        var current = data
        for _ in 0..<turns {
            var next = [Float](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    next[x * side + (side - 1 - y)] = current[y * side + x]
                }
            }
            current = next
        }
        return current
    }

    // MARK: - 打分

    /// PC 的 _ai_component：把 0.45…0.85 线性拉伸到 0…1
    static func aiComponent(_ score: Double) -> Double {
        min(1.0, max(0.0, (score - 0.45) / 0.40))
    }

    /// PC final_score：old = 7 项加权
    static func oldScore(
        local: Double,
        edge: Double,
        sims: GlobalSims
    ) -> Double {
        let value = 0.46 * local
            + 0.20 * edge
            + 0.14 * sims.fm
            + 0.10 * sims.lbp
            + 0.04 * sims.ori
            + 0.03 * sims.radial
            + 0.03 * sims.shape
        return min(0.995, max(0.0, value))
    }
}
