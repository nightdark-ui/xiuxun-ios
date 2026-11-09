import Foundation

/// CLAHE（限制对比度的自适应直方图均衡），按 OpenCV 的算法实现。
///
/// PC 端用的是 `cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8,8))`，
/// 这里复刻同一套流程：分块直方图 → 按 tileArea/256 裁剪 → 均匀补偿 → LUT → 双线性插值。
/// 与 OpenCV 的差异只在个别舍入，实测余弦可对照 probe_clahe_input.bin 验证。
enum Clahe {
    /// - Parameters:
    ///   - gray: 灰度像素（行优先，width × height）
    ///   - clipLimit: 对比度限制，PC 用 2.0
    ///   - tiles: 分块数，PC 用 8（即 8×8）
    static func apply(
        _ gray: [UInt8],
        width: Int,
        height: Int,
        clipLimit: Double = 2.0,
        tiles: Int = 8
    ) -> [UInt8] {
        guard width > 0, height > 0, gray.count >= width * height else { return gray }

        let tilesX = max(1, tiles)
        let tilesY = max(1, tiles)
        let tileW = max(1, width / tilesX)
        let tileH = max(1, height / tilesY)
        let histSize = 256

        // 每个 tile 的 LUT
        var luts = [UInt8](repeating: 0, count: tilesX * tilesY * histSize)

        for ty in 0..<tilesY {
            let y0 = ty * tileH
            let y1 = (ty == tilesY - 1) ? height : min(height, y0 + tileH)
            for tx in 0..<tilesX {
                let x0 = tx * tileW
                let x1 = (tx == tilesX - 1) ? width : min(width, x0 + tileW)
                let area = max(1, (x1 - x0) * (y1 - y0))

                var hist = [Int](repeating: 0, count: histSize)
                for y in y0..<y1 {
                    let row = y * width
                    for x in x0..<x1 {
                        hist[Int(gray[row + x])] += 1
                    }
                }

                // OpenCV：clipLimit 换算成像素数，至少为 1
                var limit = Int(clipLimit * Double(area) / Double(histSize))
                if limit < 1 { limit = 1 }

                var clipped = 0
                for i in 0..<histSize where hist[i] > limit {
                    clipped += hist[i] - limit
                    hist[i] = limit
                }
                // 均匀补偿回去
                let batch = clipped / histSize
                let residual = clipped - batch * histSize
                if batch > 0 {
                    for i in 0..<histSize { hist[i] += batch }
                }
                if residual > 0 {
                    let step = Double(histSize) / Double(residual)
                    var index = 0.0
                    var added = 0
                    while added < residual && Int(index) < histSize {
                        hist[Int(index)] += 1
                        added += 1
                        index += step
                    }
                }

                // 累积 → LUT
                let scale = Double(histSize - 1) / Double(area)
                var sum = 0
                let base = (ty * tilesX + tx) * histSize
                for i in 0..<histSize {
                    sum += hist[i]
                    let value = Int((Double(sum) * scale).rounded())
                    luts[base + i] = UInt8(min(255, max(0, value)))
                }
            }
        }

        // 双线性插值：每个像素取相邻 4 个 tile 的 LUT
        var output = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            // tile 中心坐标（与 OpenCV 一致：tileW/2 偏移）
            let fy = (Double(y) - Double(tileH) / 2.0) / Double(tileH)
            var ty0 = Int(floor(fy))
            var wy = fy - Double(ty0)
            if ty0 < 0 { ty0 = 0; wy = 0 }
            if ty0 > tilesY - 1 { ty0 = tilesY - 1; wy = 0 }
            let ty1 = min(tilesY - 1, ty0 + 1)

            for x in 0..<width {
                let fx = (Double(x) - Double(tileW) / 2.0) / Double(tileW)
                var tx0 = Int(floor(fx))
                var wx = fx - Double(tx0)
                if tx0 < 0 { tx0 = 0; wx = 0 }
                if tx0 > tilesX - 1 { tx0 = tilesX - 1; wx = 0 }
                let tx1 = min(tilesX - 1, tx0 + 1)

                let value = Int(gray[y * width + x])
                let v00 = Double(luts[((ty0 * tilesX) + tx0) * histSize + value])
                let v01 = Double(luts[((ty0 * tilesX) + tx1) * histSize + value])
                let v10 = Double(luts[((ty1 * tilesX) + tx0) * histSize + value])
                let v11 = Double(luts[((ty1 * tilesX) + tx1) * histSize + value])

                let top = v00 * (1 - wx) + v01 * wx
                let bottom = v10 * (1 - wx) + v11 * wx
                let mixed = top * (1 - wy) + bottom * wy
                output[y * width + x] = UInt8(min(255, max(0, Int(mixed.rounded()))))
            }
        }
        return output
    }
}
