import Foundation
import Accelerate

/// Fourier-Mellin 描述子（PC `features._fourier_mellin` 的 Swift 版）
///
/// 流程：structure → 192×192 → 对数极坐标(180×96) → 二维 FFT → 幅值
///      → log1p → 高斯模糊 → 16×16 → 去均值 → L2 归一化（256 维）
///
/// FFT 用 Accelerate 的 vDSP DFT（96 = 2⁵·3、180 = 2²·3²·5，均可分解）。
enum FourierMellin {
    static let workSide = 192
    static let angleCount = 180
    static let radiusCount = 96
    static let outSide = 16

    static func descriptor(edge: [Float], side: Int) -> [Float] {
        let work = resize(edge, from: side, to: workSide)
        var polar = logPolar(work)

        let spectrum = fft2Magnitude(&polar, rows: angleCount, cols: radiusCount)
        var values = spectrum.map { Float(log1p(Double($0))) }
        values = gaussianBlur(values, rows: angleCount, cols: radiusCount, sigma: 1.0)

        var small = [Float](repeating: 0, count: outSide * outSide)
        let rowStep = max(1, angleCount / outSide)
        let colStep = max(1, radiusCount / outSide)
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

    // MARK: - 对数极坐标

    private static func logPolar(_ work: [Float]) -> [Float] {
        var polar = [Float](repeating: 0, count: angleCount * radiusCount)
        let center = Double(workSide) / 2.0
        let maxRadius = Double(workSide) / 2.0
        let logMax = log(maxRadius)
        for a in 0..<angleCount {
            let angle = Double(a) / Double(angleCount) * 2.0 * Double.pi
            let cosA = cos(angle)
            let sinA = sin(angle)
            for r in 0..<radiusCount {
                let t = Double(r) / Double(radiusCount - 1)
                let radius = exp(t * logMax)
                let x = center + cosA * radius
                let y = center + sinA * radius
                polar[a * radiusCount + r] = sample(work, side: workSide, x: x, y: y)
            }
        }
        return polar
    }

    // MARK: - FFT（vDSP）

    private static func fft2Magnitude(_ input: inout [Float], rows: Int, cols: Int) -> [Float] {
        guard let rowSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(cols), .FORWARD),
              let colSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(rows), .FORWARD) else {
            return [Float](repeating: 0, count: rows * cols)
        }
        defer {
            vDSP_DFT_DestroySetup(rowSetup)
            vDSP_DFT_DestroySetup(colSetup)
        }

        // 行变换（长度 cols）
        var rowReal = [Float](repeating: 0, count: cols)
        var rowImag = [Float](repeating: 0, count: cols)
        var outReal = [Float](repeating: 0, count: cols)
        var outImag = [Float](repeating: 0, count: cols)
        var interleaved = [Float](repeating: 0, count: rows * cols * 2)

        for r in 0..<rows {
            for c in 0..<cols {
                rowReal[c] = input[r * cols + c]
                rowImag[c] = 0
            }
            vDSP_DFT_Execute(rowSetup, rowReal, rowImag, &outReal, &outImag)
            for c in 0..<cols {
                interleaved[(r * cols + c) * 2] = outReal[c]
                interleaved[(r * cols + c) * 2 + 1] = outImag[c]
            }
        }

        // 列变换（长度 rows）
        var colReal = [Float](repeating: 0, count: rows)
        var colImag = [Float](repeating: 0, count: rows)
        var colOutReal = [Float](repeating: 0, count: rows)
        var colOutImag = [Float](repeating: 0, count: rows)
        var magnitude = [Float](repeating: 0, count: rows * cols)

        let shiftRow = rows / 2
        let shiftCol = cols / 2
        for c in 0..<cols {
            for r in 0..<rows {
                colReal[r] = interleaved[(r * cols + c) * 2]
                colImag[r] = interleaved[(r * cols + c) * 2 + 1]
            }
            vDSP_DFT_Execute(colSetup, colReal, colImag, &colOutReal, &colOutImag)
            for k in 0..<rows {
                let re = colOutReal[k]
                let im = colOutImag[k]
                let value = (re * re + im * im).squareRoot()
                let shiftedRow = (k + shiftRow) % rows
                let shiftedCol = (c + shiftCol) % cols
                magnitude[shiftedRow * cols + shiftedCol] = value
            }
        }
        return magnitude
    }

    // MARK: - 工具

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
