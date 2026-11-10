import Foundation

/// Fourier-Mellin 描述子（PC `features._fourier_mellin` 的 Swift 实现）
///
/// 流程：structure → 192×192 → 对数极坐标(180×96) → 二维 FFT → 取幅值
///      → log1p → 高斯模糊 → 缩到 16×16 → 去均值 → L2 归一化（256 维）
///
/// 对数极坐标让描述子对旋转和缩放不敏感，适合区分"线条疏密/粗细"。
enum FourierMellin {
    static let workSide = 192
    static let angleCount = 180
    static let radiusCount = 96
    static let outSide = 16

    /// - Parameter edge: 80×80 或任意方形边缘图（0…1）
    static func descriptor(edge: [Float], side: Int) -> [Float] {
        // 1) 放大到 192×192（双线性）
        let work = resize(edge, from: side, to: workSide)

        // 2) 对数极坐标采样：rows = 角度，cols = 半径
        var polar = [Float](repeating: 0, count: angleCount * radiusCount)
        let center = Double(workSide) / 2.0
        let maxRadius = Double(workSide) / 2.0
        let logMax = log(maxRadius)
        for a in 0..<angleCount {
            let angle = Double(a) / Double(angleCount) * 2.0 * Double.pi
            let cosA = cos(angle)
            let sinA = sin(angle)
            for r in 0..<radiusCount {
                // 对数半径：r=0 对应 1 像素，r=max 对应 maxRadius
                let t = Double(r) / Double(radiusCount - 1)
                let radius = exp(t * logMax)
                let x = center + cosA * radius
                let y = center + sinA * radius
                polar[a * radiusCount + r] = sample(work, side: workSide, x: x, y: y)
            }
        }

        // 3) 二维 DFT（对数极坐标尺寸不大，直接 O(n²) 可接受）
        let spectrum = fft2Magnitude(polar, rows: angleCount, cols: radiusCount)

        // 4) log1p
        var values = spectrum.map { Float(log1p(Double($0))) }

        // 5) 高斯模糊（σ=1，分离卷积）
        values = gaussianBlur(values, rows: angleCount, cols: radiusCount, sigma: 1.0)

        // 6) 缩小到 16×16（区域平均）
        var small = [Float](repeating: 0, count: outSide * outSide)
        let rowStep = angleCount / outSide
        let colStep = radiusCount / outSide
        for gy in 0..<outSide {
            for gx in 0..<outSide {
                var sum: Float = 0
                var count = 0
                for y in (gy * rowStep)..<min(angleCount, (gy + 1) * rowStep) {
                    for x in (gx * colStep)..<min(radiusCount, (gx + 1) * colStep) {
                        sum += values[y * radiusCount + x]
                        count += 1
                    }
                }
                small[gy * outSide + gx] = count > 0 ? sum / Float(count) : 0
            }
        }

        // 7) 去均值 + L2 归一化
        let mean = small.reduce(0, +) / Float(small.count)
        var centered = small.map { $0 - mean }
        var norm: Float = 0
        for v in centered { norm += v * v }
        norm = sqrt(norm)
        if norm > 1e-6 {
            for i in 0..<centered.count { centered[i] /= norm }
        }
        return centered
    }

    // MARK: - 内部

    private static func resize(_ source: [Float], from side: Int, to target: Int) -> [Float] {
        guard side > 1, side != target else { return source }
        var output = [Float](repeating: 0, count: target * target)
        let scale = Double(side - 1) / Double(target - 1)
        for y in 0..<target {
            let sy = Double(y) * scale
            let y0 = Int(sy)
            let y1 = min(side - 1, y0 + 1)
            let fy = Float(sy - Double(y0))
            for x in 0..<target {
                let sx = Double(x) * scale
                let x0 = Int(sx)
                let x1 = min(side - 1, x0 + 1)
                let fx = Float(sx - Double(x0))
                let v00 = source[y0 * side + x0]
                let v01 = source[y0 * side + x1]
                let v10 = source[y1 * side + x0]
                let v11 = source[y1 * side + x1]
                let top = v00 * (1 - fx) + v01 * fx
                let bottom = v10 * (1 - fx) + v11 * fx
                output[y * target + x] = top * (1 - fy) + bottom * fy
            }
        }
        return output
    }

    private static func sample(_ data: [Float], side: Int, x: Double, y: Double) -> Float {
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = x0 + 1
        let y1 = y0 + 1
        guard x0 >= 0, y0 >= 0, x1 < side, y1 < side else { return 0 }
        let fx = Float(x - Double(x0))
        let fy = Float(y - Double(y0))
        let v00 = data[y0 * side + x0]
        let v01 = data[y0 * side + x1]
        let v10 = data[y1 * side + x0]
        let v11 = data[y1 * side + x1]
        let top = v00 * (1 - fx) + v01 * fx
        let bottom = v10 * (1 - fx) + v11 * fx
        return top * (1 - fy) + bottom * fy
    }

    /// 二维 DFT 幅值（含 fftshift）
    private static func fft2Magnitude(_ input: [Float], rows: Int, cols: Int) -> [Float] {
        // 行方向 DFT
        var rowTransformed = [Double](repeating: 0, count: rows * cols * 2)
        for r in 0..<rows {
            for k in 0..<cols {
                var re = 0.0
                var im = 0.0
                for n in 0..<cols {
                    let angle = -2.0 * Double.pi * Double(k * n) / Double(cols)
                    let value = Double(input[r * cols + n])
                    re += value * cos(angle)
                    im += value * sin(angle)
                }
                rowTransformed[(r * cols + k) * 2] = re
                rowTransformed[(r * cols + k) * 2 + 1] = im
            }
        }
        // 列方向 DFT
        var magnitude = [Float](repeating: 0, count: rows * cols)
        for c in 0..<cols {
            for k in 0..<rows {
                var re = 0.0
                var im = 0.0
                for n in 0..<rows {
                    let angle = -2.0 * Double.pi * Double(k * n) / Double(rows)
                    let vr = rowTransformed[(n * cols + c) * 2]
                    let vi = rowTransformed[(n * cols + c) * 2 + 1]
                    re += vr * cos(angle) - vi * sin(angle)
                    im += vr * sin(angle) + vi * cos(angle)
                }
                magnitude[((k + rows / 2) % rows) * cols + ((c + cols / 2) % cols)] =
                    Float((re * re + im * im).squareRoot())
            }
        }
        return magnitude
    }

    private static func gaussianBlur(_ data: [Float], rows: Int, cols: Int, sigma: Double) -> [Float] {
        let radius = 2
        var kernel = [Double](repeating: 0, count: radius * 2 + 1)
        var sum = 0.0
        for i in -radius...radius {
            let value = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = value
            sum += value
        }
        kernel = kernel.map { $0 / sum }

        var temp = [Float](repeating: 0, count: rows * cols)
        for y in 0..<rows {
            for x in 0..<cols {
                var acc = 0.0
                for k in -radius...radius {
                    let xx = min(cols - 1, max(0, x + k))
                    acc += Double(data[y * cols + xx]) * kernel[k + radius]
                }
                temp[y * cols + x] = Float(acc)
            }
        }
        var output = [Float](repeating: 0, count: rows * cols)
        for y in 0..<rows {
            for x in 0..<cols {
                var acc = 0.0
                for k in -radius...radius {
                    let yy = min(rows - 1, max(0, y + k))
                    acc += Double(temp[yy * cols + x]) * kernel[k + radius]
                }
                output[y * cols + x] = Float(acc)
            }
        }
        return output
    }
}
