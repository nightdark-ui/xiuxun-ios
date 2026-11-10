import Foundation

/// 循环花型增强（对应 PC `query_normalize.repeat_cycle_variants`）。
///
/// 思路：用边缘强度剖面的自相关找重复周期，裁出若干相位偏移的"重复单元"和一块 2×2，
/// 作为**额外的查询变体**参与编码。只影响查询侧，不动图库索引。
enum RepeatVariants {

    /// 估计一维信号的周期（自相关峰），返回 (lag, score)
    static func period(_ signal: [Double]) -> (lag: Int, score: Double)? {
        let length = signal.count
        guard length >= 32 else { return nil }
        let mean = signal.reduce(0, +) / Double(length)
        var centered = signal.map { $0 - mean }
        let energy = centered.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-6 else { return nil }

        var corr = [Double](repeating: 0, count: length)
        for lag in 0..<length {
            var sum = 0.0
            var i = 0
            while i + lag < length {
                sum += centered[i] * centered[i + lag]
                i += 1
            }
            corr[lag] = sum
        }
        _ = centered
        guard corr[0] > 0 else { return nil }
        let normalized = corr.map { $0 / corr[0] }

        let low = max(8, Int(Double(length) * 0.10))
        let high = min(length - 2, Int(Double(length) * 0.55))
        guard high > low + 2 else { return nil }

        var bestLag: Int?
        var bestScore = -1.0
        for lag in low..<high {
            if normalized[lag] >= normalized[lag - 1],
               normalized[lag] >= normalized[lag + 1],
               normalized[lag] > bestScore {
                bestScore = normalized[lag]
                bestLag = lag
            }
        }
        guard let lag = bestLag, bestScore >= 0.16 else { return nil }
        return (lag, bestScore)
    }

    /// 生成重复单元变体（最多 5 个：4 个相位 + 1 个 2×2）
    static func variants(_ image: PilImaging.GrayImage) -> [PilImaging.GrayImage] {
        let width = image.width
        let height = image.height
        guard width >= 64, height >= 64 else { return [] }

        // 边缘强度剖面（沿 x 平均得到横向周期，沿 y 平均得到纵向周期）
        var columnProfile = [Double](repeating: 0, count: width)
        var rowProfile = [Double](repeating: 0, count: height)
        for y in 1..<(height - 1) {
            let row = y * width
            let up = (y - 1) * width
            let down = (y + 1) * width
            for x in 1..<(width - 1) {
                let gx = Double(image.pixels[row + x + 1]) - Double(image.pixels[row + x - 1])
                let gy = Double(image.pixels[down + x]) - Double(image.pixels[up + x])
                let magnitude = (gx * gx + gy * gy).squareRoot()
                columnProfile[x] += magnitude
                rowProfile[y] += magnitude
            }
        }

        let horizontal = period(columnProfile)
        let vertical = period(rowProfile)
        let horizontalOK = (horizontal?.score ?? 0) >= 0.18
        let verticalOK = (vertical?.score ?? 0) >= 0.18
        guard horizontalOK || verticalOK else { return [] }

        var unitW: Int
        var unitH: Int
        if horizontalOK && verticalOK {
            unitW = Int(Double(horizontal!.lag) * 1.12)
            unitH = Int(Double(vertical!.lag) * 1.12)
        } else if horizontalOK {
            unitW = Int(Double(horizontal!.lag) * 1.12)
            unitH = unitW
        } else {
            unitH = Int(Double(vertical!.lag) * 1.12)
            unitW = unitH
        }
        unitW = max(24, min(unitW, width))
        unitH = max(24, min(unitH, height))

        let minSide = min(width, height)
        if Double(unitW) < Double(minSide) * 0.18 || Double(unitH) < Double(minSide) * 0.18 {
            return []
        }
        if unitW * unitH > Int(Double(width * height) * 0.72) {
            return []
        }

        var result: [PilImaging.GrayImage] = []
        let cx = width / 2
        let cy = height / 2
        for phase in [0.0, 0.25, 0.5, 0.75] {
            var left = Int(Double(cx) - Double(unitW) / 2 + (phase - 0.25) * Double(unitW) * 0.8)
            var top = Int(Double(cy) - Double(unitH) / 2 + (phase - 0.25) * Double(unitH) * 0.8)
            left = max(0, min(width - unitW, left))
            top = max(0, min(height - unitH, top))
            if let crop = crop(image, left: left, top: top, width: unitW, height: unitH) {
                result.append(crop)
            }
        }

        let w2 = min(width, unitW * 2)
        let h2 = min(height, unitH * 2)
        if w2 * h2 <= Int(Double(width * height) * 0.90) {
            let left = max(0, min(width - w2, cx - w2 / 2))
            let top = max(0, min(height - h2, cy - h2 / 2))
            if let crop = crop(image, left: left, top: top, width: w2, height: h2) {
                result.append(crop)
            }
        }
        return result
    }

    private static func crop(
        _ image: PilImaging.GrayImage,
        left: Int,
        top: Int,
        width: Int,
        height: Int
    ) -> PilImaging.GrayImage? {
        guard width > 8, height > 8,
              left >= 0, top >= 0,
              left + width <= image.width,
              top + height <= image.height else { return nil }
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let source = (top + y) * image.width + left
            for x in 0..<width { output[y * width + x] = image.pixels[source + x] }
        }
        return PilImaging.GrayImage(width: width, height: height, pixels: output)
    }
}
