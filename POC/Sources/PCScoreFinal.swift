import Foundation

/// PC 最终打分：score = 0.75 × aiComponent + 0.25 × oldScore
/// aiComponent(x) = clip((x - 0.45) / 0.40, 0, 1)
/// oldScore = 0.46×SIFT + 0.20×edge + 0.14×fm + 0.10×lbp + 0.04×ori + 0.03×radial + 0.03×shape
enum PCScoreFinal {

    static func aiComponent(_ value: Double) -> Double {
        min(1.0, max(0.0, (value - 0.45) / 0.40))
    }

    struct SimStats {
        var fm: Double = 0
        var lbp: Double = 0
        var ori: Double = 0
        var radial: Double = 0
        var hu: Double = 0
        var stats: Double = 0
        var shape: Double = 0
    }

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

    static func histogramIntersection(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        var sum = 0.0
        for i in 0..<count { sum += Double(min(a[i], b[i])) }
        return min(1.0, sum)
    }

    /// PC 的 compare_global
    static func compareGlobal(
        query: PCGlobal.Descriptor,
        design: HeavyStore.DesignFeatures
    ) -> SimStats {
        let fm = cosine(query.fm, design.fm)
        let lbp = histogramIntersection(query.lbp, design.lbp)
        let ori = cosine(query.ori, design.ori)
        let radial = cosine(query.radial, design.radial)
        let hu = StructureScore.huSimilarity(query.hu, design.hu)
        let stats = StructureScore.statsSimilarity(query.stats, design.stats)
        let shape = min(1, max(0, 0.72 * fm + 0.12 * hu + 0.16 * stats))
        return SimStats(
            fm: fm, lbp: lbp, ori: ori, radial: radial,
            hu: hu, stats: stats, shape: shape
        )
    }

    /// PC 的 final_score（几何分）
    static func oldScore(local: Double, edge: Double, stats: SimStats) -> Double {
        let value = 0.46 * local
            + 0.20 * edge
            + 0.14 * stats.fm
            + 0.10 * stats.lbp
            + 0.04 * stats.ori
            + 0.03 * stats.radial
            + 0.03 * stats.shape
        return min(0.995, max(0.0, value))
    }
}
