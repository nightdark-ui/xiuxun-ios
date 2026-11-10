import Foundation
import UIKit

/// 结构与全局描述子相似度（对应 PC `matching.compare_global` + `edge_correlation`）
///
/// PC 公式：
///   shape     = 0.72×fm + 0.12×hu + 0.16×stats
///   texture   = 0.72×lbp + 0.16×ori + 0.12×radial
///   structure = 0.62×edge + 0.38×shape
///   final     = 0.75×ai + 0.25×(structure/100 归一化后的 old)
///
/// iOS 实现说明：
///   - edge(80×80)、fm、hu、stats 图库侧都在 heavy.bin 里
///   - 查询侧这里计算 edge80 / hu7 / stats4；fm（FFT 矩）暂未实现，
///     因此 shape 用 hu + stats 按原权重比例归一化后近似
enum StructureScore {
    static let edgeSide = 80

    // MARK: - 查询侧描述子

    struct QueryDescriptor {
        var edge: [Float]      // 80×80，已归一化
        var fm: [Float]        // Fourier-Mellin 256 维
        var hu: [Float]        // 7
        var stats: [Float]     // 4
    }

    static func describe(_ image: PilImaging.GrayImage) -> QueryDescriptor {
        let edge = edgeMap(image)
        let hu = huMoments(edge, side: edgeSide)
        let stats = simpleStats(image)
        let fm = FourierMellin.descriptor(edge: edge, side: edgeSide)
        return QueryDescriptor(edge: edge, fm: fm, hu: hu, stats: stats)
    }

    /// 80×80 梯度幅值图（归一化到 0…1）
    static func edgeMap(_ image: PilImaging.GrayImage) -> [Float] {
        let side = edgeSide
        var small = [Double](repeating: 0, count: side * side)
        let w = image.width
        let h = image.height
        guard w > 1, h > 1 else { return [Float](repeating: 0, count: side * side) }

        // 最近邻缩放
        for y in 0..<side {
            let sy = min(h - 1, y * h / side)
            for x in 0..<side {
                let sx = min(w - 1, x * w / side)
                small[y * side + x] = Double(image.pixels[sy * w + sx])
            }
        }

        var edge = [Float](repeating: 0, count: side * side)
        var maxValue = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let gx = small[y * side + x + 1] - small[y * side + x - 1]
                let gy = small[(y + 1) * side + x] - small[(y - 1) * side + x]
                let magnitude = (gx * gx + gy * gy).squareRoot()
                edge[y * side + x] = Float(magnitude)
                if magnitude > maxValue { maxValue = magnitude }
            }
        }
        if maxValue > 1e-6 {
            for i in 0..<edge.count { edge[i] = Float(Double(edge[i]) / maxValue) }
        }
        return edge
    }

    /// 7 个 Hu 不变矩（基于二值化边缘图）
    static func huMoments(_ edge: [Float], side: Int) -> [Float] {
        let threshold: Float = 0.25
        var m00 = 0.0, m10 = 0.0, m01 = 0.0
        for y in 0..<side {
            for x in 0..<side where edge[y * side + x] >= threshold {
                let v = Double(edge[y * side + x])
                m00 += v
                m10 += v * Double(x)
                m01 += v * Double(y)
            }
        }
        guard m00 > 1e-6 else { return [Float](repeating: 0, count: 7) }
        let cx = m10 / m00
        let cy = m01 / m00

        var mu = [Double](repeating: 0, count: 8)   // mu20, mu02, mu11, mu30, mu03, mu21, mu12, mu00(no)
        var mu20 = 0.0, mu02 = 0.0, mu11 = 0.0
        var mu30 = 0.0, mu03 = 0.0, mu21 = 0.0, mu12 = 0.0
        for y in 0..<side {
            for x in 0..<side where edge[y * side + x] >= threshold {
                let v = Double(edge[y * side + x])
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                mu20 += v * dx * dx
                mu02 += v * dy * dy
                mu11 += v * dx * dy
                mu30 += v * dx * dx * dx
                mu03 += v * dy * dy * dy
                mu21 += v * dx * dx * dy
                mu12 += v * dx * dy * dy
            }
        }
        let n20 = mu20 / pow(m00, 2.0)
        let n02 = mu02 / pow(m00, 2.0)
        let n11 = mu11 / pow(m00, 2.0)
        let n30 = mu30 / pow(m00, 2.5)
        let n03 = mu03 / pow(m00, 2.5)
        let n21 = mu21 / pow(m00, 2.5)
        let n12 = mu12 / pow(m00, 2.5)

        var hu = [Double](repeating: 0, count: 7)
        hu[0] = n20 + n02
        hu[1] = (n20 - n02) * (n20 - n02) + 4 * n11 * n11
        hu[2] = (n30 - 3 * n12) * (n30 - 3 * n12) + (3 * n21 - n03) * (3 * n21 - n03)
        hu[3] = (n30 + n12) * (n30 + n12) + (n21 + n03) * (n21 + n03)
        hu[4] = (n30 - 3 * n12) * (n30 + n12) * ((n30 + n12) * (n30 + n12) - 3 * (n21 + n03) * (n21 + n03))
            + (3 * n21 - n03) * (n21 + n03) * (3 * (n30 + n12) * (n30 + n12) - (n21 + n03) * (n21 + n03))
        hu[5] = (n20 - n02) * ((n30 + n12) * (n30 + n12) - (n21 + n03) * (n21 + n03))
            + 4 * n11 * (n30 + n12) * (n21 + n03)
        hu[6] = (3 * n21 - n03) * (n30 + n12) * ((n30 + n12) * (n30 + n12) - 3 * (n21 + n03) * (n21 + n03))
            - (n30 - 3 * n12) * (n21 + n03) * (3 * (n30 + n12) * (n30 + n12) - (n21 + n03) * (n21 + n03))

        // 取对数压缩动态范围（标准做法）
        var result = [Float](repeating: 0, count: 7)
        for i in 0..<7 {
            let value = abs(hu[i]) + 1e-12
            result[i] = Float(-log10(value) / 10.0)
        }
        _ = mu
        return result
    }

    /// 4 个统计量：均值、标准差、边缘密度、对比度（都归一化到 0…1）
    static func simpleStats(_ image: PilImaging.GrayImage) -> [Float] {
        let count = image.pixels.count
        guard count > 0 else { return [0, 0, 0, 0] }
        var sum = 0.0
        var sumSq = 0.0
        var edges = 0.0
        for i in 0..<count {
            let v = Double(image.pixels[i]) / 255.0
            sum += v
            sumSq += v * v
        }
        let mean = sum / Double(count)
        let variance = max(0, sumSq / Double(count) - mean * mean)
        // 边缘密度：相邻像素差超过阈值的比例
        let w = image.width
        for i in stride(from: 0, to: count - 1, by: 1) where i % w != w - 1 {
            if abs(Int(image.pixels[i + 1]) - Int(image.pixels[i])) > 24 { edges += 1 }
        }
        let density = edges / Double(count)
        let contrast = min(1.0, sqrt(variance) * 4)
        return [Float(mean), Float(sqrt(variance)), Float(density), Float(contrast)]
    }

    // MARK: - 相似度

    /// 边缘图相关度（去均值余弦）
    static func edgeCorrelation(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var meanA = 0.0, meanB = 0.0
        for i in 0..<count { meanA += Double(a[i]); meanB += Double(b[i]) }
        meanA /= Double(count)
        meanB /= Double(count)
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<count {
            let x = Double(a[i]) - meanA
            let y = Double(b[i]) - meanB
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 1e-9, nb > 1e-9 else { return 0 }
        return max(0, dot / (sqrt(na) * sqrt(nb)))
    }

    /// Fourier-Mellin 相似度（两者都已归一化，直接点积）
    static func fmSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot = 0.0
        for i in 0..<count { dot += Double(a[i]) * Double(b[i]) }
        return dot
    }

    /// Hu 矩相似度：exp(-4 × 平均绝对差)（PC 同公式）
    static func huSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<count { sum += abs(Double(a[i]) - Double(b[i])) }
        return exp(-4.0 * (sum / Double(count)))
    }

    /// 统计量相似度：exp(-平均加权绝对差)（PC 同公式）
    static func statsSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let weights: [Double] = [5.0, 4.0, 4.0, 3.0]
        let count = min(min(a.count, b.count), weights.count)
        guard count > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<count { sum += abs(Double(a[i]) - Double(b[i])) * weights[i] }
        return exp(-(sum / Double(count)))
    }

    /// 结构分（0…1）：0.62×edge + 0.38×shape，shape 用 hu+stats 按原比例归一化
    static func structure(
        query: QueryDescriptor,
        designEdge: [Float],
        designFm: [Float],
        designHu: [Float],
        designStats: [Float]
    ) -> Double {
        let edge = edgeCorrelation(query.edge, designEdge)
        let hu = huSimilarity(query.hu, designHu)
        let stats = statsSimilarity(query.stats, designStats)
        // PC: shape = 0.72×fm + 0.12×hu + 0.16×stats
        let fm = max(0, fmSimilarity(query.fm, designFm))
        let shape = 0.72 * fm + 0.12 * hu + 0.16 * stats
        return min(1.0, max(0.0, 0.62 * edge + 0.38 * shape))
    }
}
