import Foundation
import Accelerate

/// PC `features.global_descriptor` 的忠实移植
/// edge(160) / fm(256) / lbp(20) / ori(14) / radial(28) / hu(7) / stats(4)
enum PCGlobal {
    static let edgeSide = 160

    struct Descriptor {
        var edge: [Float]      // 160×160，0…255
        var fm: [Float]        // 256
        var lbp: [Float]       // 20
        var ori: [Float]       // 14
        var radial: [Float]    // 28
        var hu: [Float]        // 7
        var stats: [Float]     // 4
    }

    static func describe(structure: [UInt8], side: Int) -> Descriptor {
        let edgeBytes = resizeArea(structure, from: side, to: edgeSide)
        let edge = edgeBytes.map { Float($0) }
        return Descriptor(
            edge: edge,
            fm: fourierMellin(structure, side: side),
            lbp: textureHistograms(structure, side: side),
            ori: orientationSignature(edge),
            radial: radialSignature(edge),
            hu: huSignature(structure, side: side),
            stats: edgeStats(structure, side: side)
        )
    }

    // MARK: - LBP（RIU2，两尺度拼接）

    private static let lbpOffsets: [(Int, Int)] = [
        (-1, -1), (-1, 0), (-1, 1), (0, 1),
        (1, 1), (1, 0), (1, -1), (0, -1)
    ]

    static func riu2LBP(_ structure: [UInt8], side: Int, target: Int) -> [Float] {
        let gray = resizeArea(structure, from: side, to: target)
        var histogram = [Float](repeating: 0, count: 10)
        let inner = target - 2
        guard inner > 0 else { return histogram }
        for y in 1...(target - 2) {
            for x in 1...(target - 2) {
                let center = Int16(gray[y * target + x])
                var bits = 0
                for (index, offset) in lbpOffsets.enumerated() {
                    let neighbor = Int16(gray[(y + offset.0) * target + (x + offset.1)])
                    if neighbor >= center { bits |= (1 << index) }
                }
                var transitions = 0
                for index in 0..<8 {
                    let current = (bits >> index) & 1
                    let following = (bits >> ((index + 1) % 8)) & 1
                    transitions += current ^ following
                }
                let ones = bits.nonzeroBitCount
                let label = transitions <= 2 ? ones : 9
                histogram[min(9, label)] += 1
            }
        }
        let total = max(1.0, Float(inner * inner))
        for i in 0..<histogram.count { histogram[i] /= total }
        return histogram
    }

    static func textureHistograms(_ structure: [UInt8], side: Int) -> [Float] {
        let first = riu2LBP(structure, side: side, target: 256)
        let second = riu2LBP(structure, side: side, target: 160)
        return first + second
    }

    // MARK: - 方向谱（36 桶直方图 → FFT → 取 1..14）

    static func orientationSignature(_ edge: [Float]) -> [Float] {
        let side = edgeSide
        var bins = [Double](repeating: 0, count: 36)
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let v = edge[y * side + x] / 255.0
                let l = edge[y * side + x - 1] / 255.0
                let r = edge[y * side + x + 1] / 255.0
                let t = edge[(y - 1) * side + x] / 255.0
                let b = edge[(y + 1) * side + x] / 255.0
                let gx = (r - l) * 2 + (edge[(y + 1) * side + x + 1] / 255.0 - edge[(y + 1) * side + x - 1] / 255.0)
                    + (edge[(y - 1) * side + x + 1] / 255.0 - edge[(y - 1) * side + x - 1] / 255.0)
                let gy = (b - t) * 2 + (edge[(y + 1) * side + x + 1] / 255.0 - edge[(y - 1) * side + x + 1] / 255.0)
                    + (edge[(y + 1) * side + x - 1] / 255.0 - edge[(y - 1) * side + x - 1] / 255.0)
                let magnitude = Double((gx * gx + gy * gy).squareRoot())
                guard magnitude > 0 else { continue }
                var angle = Double(atan2(gy, gx)) + Double.pi
                angle = angle.truncatingRemainder(dividingBy: Double.pi)
                let index = min(35, Int(angle / Double.pi * 35.999))
                bins[index] += magnitude
                _ = v
            }
        }
        guard bins.reduce(0, +) > 1e-6 else { return [Float](repeating: 0, count: 14) }
        let spectrum = dftRealMagnitude(bins)
        var signature = Array(spectrum[1..<15])
        let norm = signature.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 1e-6 {
            for i in 0..<signature.count { signature[i] /= norm }
        }
        return signature.map { Float($0) }
    }

    // MARK: - 径向谱

    static func radialSignature(_ edge: [Float]) -> [Float] {
        let side = edgeSide
        // Hanning 窗
        var windowed = [Double](repeating: 0, count: side * side)
        let hanning = (0..<side).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(side - 1)) }
        for y in 0..<side {
            for x in 0..<side {
                windowed[y * side + x] = Double(edge[y * side + x]) * hanning[y] * hanning[x]
            }
        }
        let magnitude = fft2Magnitude(windowed, side: side)
        let center = Double(side) / 2.0
        var radial = [Double](repeating: 0, count: 28)
        var counts = [Double](repeating: 0, count: 28)
        for y in 0..<side {
            for x in 0..<side {
                let dy = Double(y) - center
                let dx = Double(x) - center
                let radius = (dy * dy + dx * dx).squareRoot()
                for index in 0..<28 {
                    let low = Double(index + 1) * 2.2
                    let high = Double(index + 2) * 2.2
                    if radius >= low && radius < high {
                        radial[index] += magnitude[y * side + x]
                        counts[index] += 1
                        break
                    }
                }
            }
        }
        for i in 0..<28 {
            if counts[i] > 0 {
                radial[i] = log1p(radial[i] / counts[i])
            }
        }
        let sum = radial.reduce(0, +)
        guard sum > 1e-6 else { return [Float](repeating: 0, count: 28) }
        let norm = radial.reduce(0) { $0 + $1 * $1 }.squareRoot()
        if norm > 1e-6 {
            for i in 0..<radial.count { radial[i] /= norm }
        }
        return radial.map { Float($0) }
    }

    // MARK: - Fourier-Mellin（复用已有实现，输入 512 结构图）

    static func fourierMellin(_ structure: [UInt8], side: Int) -> [Float] {
        let small = resize(structure, from: side, to: 192).map { Float($0) / 255.0 }
        return FourierMellin.descriptor(edge: small, side: 192)
    }

    // MARK: - Hu + 统计量

    static func huSignature(_ structure: [UInt8], side: Int) -> [Float] {
        let small = resizeArea(structure, from: side, to: 160)
        let binary = small.map { $0 > 48 }
        var m00 = 0.0, m10 = 0.0, m01 = 0.0
        for y in 0..<160 {
            for x in 0..<160 where binary[y * 160 + x] {
                m00 += 1
                m10 += Double(x)
                m01 += Double(y)
            }
        }
        guard m00 > 1e-6 else { return [Float](repeating: 0, count: 7) }
        let cx = m10 / m00, cy = m01 / m00
        var mu20 = 0.0, mu02 = 0.0, mu11 = 0.0
        var mu30 = 0.0, mu03 = 0.0, mu21 = 0.0, mu12 = 0.0
        for y in 0..<160 {
            for x in 0..<160 where binary[y * 160 + x] {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                mu20 += dx * dx
                mu02 += dy * dy
                mu11 += dx * dy
                mu30 += dx * dx * dx
                mu03 += dy * dy * dy
                mu21 += dx * dx * dy
                mu12 += dx * dy * dy
            }
        }
        let n20 = mu20 / pow(m00, 2), n02 = mu02 / pow(m00, 2), n11 = mu11 / pow(m00, 2)
        let n30 = mu30 / pow(m00, 2.5), n03 = mu03 / pow(m00, 2.5)
        let n21 = mu21 / pow(m00, 2.5), n12 = mu12 / pow(m00, 2.5)

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

        // PC: -sign(hu) * log10(|hu|+1e-12)，clip 0…22，再 /22
        var result = [Float](repeating: 0, count: 7)
        for i in 0..<7 {
            let value = hu[i]
            let logged = (value < 0 ? 1.0 : -1.0) * log10(abs(value) + 1e-12)
            let clamped = min(22.0, max(0.0, logged))
            result[i] = Float(clamped / 22.0)
        }
        return result
    }

    static func edgeStats(_ structure: [UInt8], side: Int) -> [Float] {
        let small = resizeArea(structure, from: side, to: 192)
        let values = small.map { Float($0) / 255.0 }
        let density = Float(values.filter { $0 > 0.18 }.count) / Float(values.count)

        var histogram = [Float](repeating: 0, count: 16)
        for value in values {
            let bin = min(15, max(0, Int(value * 16)))
            histogram[bin] += 1
        }
        let total = max(1.0, histogram.reduce(0, +))
        var entropy: Float = 0
        for value in histogram {
            let probability = value / total
            if probability > 0 {
                entropy -= probability * log2(probability + 1e-9)
            }
        }
        entropy /= 4.0
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return [density, mean, variance.squareRoot(), entropy]
    }

    // MARK: - 缩放 / FFT

    /// 面积平均缩放（对应 cv2.INTER_AREA，PC 的 lbp/hu/stats/edge 都用它）
    static func resizeArea(_ source: [UInt8], from side: Int, to target: Int) -> [UInt8] {
        guard side != target, side > 1, target > 1 else { return source }
        var output = [UInt8](repeating: 0, count: target * target)
        let ratio = Double(side) / Double(target)
        for y in 0..<target {
            let y0 = Int(Double(y) * ratio)
            let y1 = min(side, max(y0 + 1, Int(Double(y + 1) * ratio)))
            for x in 0..<target {
                let x0 = Int(Double(x) * ratio)
                let x1 = min(side, max(x0 + 1, Int(Double(x + 1) * ratio)))
                var sum = 0.0
                var count = 0
                for yy in y0..<y1 {
                    for xx in x0..<x1 {
                        sum += Double(source[yy * side + xx])
                        count += 1
                    }
                }
                output[y * target + x] = UInt8(min(255, max(0, sum / Double(max(count, 1)))))
            }
        }
        return output
    }

    static func resize(_ source: [UInt8], from side: Int, to target: Int) -> [UInt8] {
        guard side != target, side > 1 else { return source }
        var output = [UInt8](repeating: 0, count: target * target)
        let scale = Double(side - 1) / Double(target - 1)
        for y in 0..<target {
            let sy = Double(y) * scale
            let y0 = Int(sy)
            let y1 = min(side - 1, y0 + 1)
            let fy = Double(sy) - Double(y0)
            for x in 0..<target {
                let sx = Double(x) * scale
                let x0 = Int(sx)
                let x1 = min(side - 1, x0 + 1)
                let fx = Double(sx) - Double(x0)
                let v00 = Double(source[y0 * side + x0])
                let v01 = Double(source[y0 * side + x1])
                let v10 = Double(source[y1 * side + x0])
                let v11 = Double(source[y1 * side + x1])
                let top = v00 * (1 - fx) + v01 * fx
                let bottom = v10 * (1 - fx) + v11 * fx
                output[y * target + x] = UInt8(min(255, max(0, top * (1 - fy) + bottom * fy)))
            }
        }
        return output
    }

    /// 实数序列的 DFT 幅值（长度 36，直接 O(n²)）
    private static func dftRealMagnitude(_ input: [Double]) -> [Double] {
        let n = input.count
        guard n > 0, let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD) else {
            return [Double](repeating: 0, count: n)
        }
        defer { vDSP_DFT_DestroySetup(setup) }
        var real = input.map { Float($0) }
        var imag = [Float](repeating: 0, count: n)
        var outReal = [Float](repeating: 0, count: n)
        var outImag = [Float](repeating: 0, count: n)
        vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)
        real = []
        imag = []
        return (0..<n).map { Double((outReal[$0] * outReal[$0] + outImag[$0] * outImag[$0]).squareRoot()) }
    }

    /// 二维 FFT 幅值
    private static func fft2Magnitude(_ input: [Double], side: Int) -> [Double] {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(side), .FORWARD) else {
            return [Double](repeating: 0, count: side * side)
        }
        defer { vDSP_DFT_DestroySetup(setup) }

        var real = [Float](repeating: 0, count: side)
        var imag = [Float](repeating: 0, count: side)
        var outReal = [Float](repeating: 0, count: side)
        var outImag = [Float](repeating: 0, count: side)
        var interleaved = [Double](repeating: 0, count: side * side * 2)

        for row in 0..<side {
            for col in 0..<side {
                real[col] = Float(input[row * side + col])
                imag[col] = 0
            }
            vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)
            for col in 0..<side {
                interleaved[(row * side + col) * 2] = Double(outReal[col])
                interleaved[(row * side + col) * 2 + 1] = Double(outImag[col])
            }
        }

        var magnitude = [Double](repeating: 0, count: side * side)
        for col in 0..<side {
            for row in 0..<side {
                real[row] = Float(interleaved[(row * side + col) * 2])
                imag[row] = Float(interleaved[(row * side + col) * 2 + 1])
            }
            vDSP_DFT_Execute(setup, real, imag, &outReal, &outImag)
            for k in 0..<side {
                let re = Double(outReal[k])
                let im = Double(outImag[k])
                magnitude[k * side + col] = (re * re + im * im).squareRoot()
            }
        }
        return magnitude
    }
}
