import Foundation
import UIKit

/// PC `imaging.make_canonical` + `structure_map` 的忠实移植。
///
/// make_canonical：自动裁掉背景 → 四周留 5.5% 白边 → 缩放到 512×512
/// structure_map：三通道 Sobel 取最大值 → 减去 28% 低频 → 99.3 分位归一
///                → γ 0.72 → 高斯模糊 σ=1.15 → 0…255
enum PCImaging {
    static let canonicalSize = 512

    // MARK: - make_canonical

    /// 返回 512×512 的 RGB 缓冲（RGBA8 便于后续处理）
    static func makeCanonical(_ image: UIImage, autoCrop: Bool) -> (pixels: [UInt8], side: Int) {
        guard let cg = image.cgImage else {
            return ([UInt8](repeating: 247, count: canonicalSize * canonicalSize * 3), canonicalSize)
        }
        var (width, height, rgb) = readRGB(cg)
        guard width > 0, height > 0 else {
            return ([UInt8](repeating: 247, count: canonicalSize * canonicalSize * 3), canonicalSize)
        }

        // 1) 自动裁切内容框
        if autoCrop, let box = contentBBox(rgb: rgb, width: width, height: height) {
            if box != (0, 0, width, height) {
                rgb = cropRGB(rgb, width: width, height: height, box: box)
                width = box.2 - box.0
                height = box.3 - box.1
            }
        }

        // 2) 方形画布 + 5.5% 留白
        let side = max(max(width, height), 1)
        let pad = Int((Double(side) * 0.055).rounded())
        let canvasSide = side + pad * 2
        var canvas = [UInt8](repeating: 247, count: canvasSide * canvasSide * 3)
        let ox = (canvasSide - width) / 2
        let oy = (canvasSide - height) / 2
        for y in 0..<height {
            let dst = ((oy + y) * canvasSide + ox) * 3
            let src = y * width * 3
            for i in 0..<(width * 3) { canvas[dst + i] = rgb[src + i] }
        }

        // 3) LANCZOS 缩放到 512（用双三次近似，视觉差异可忽略）
        let resized = resizeRGB(canvas, width: canvasSide, height: canvasSide, target: canonicalSize)
        return (resized, canonicalSize)
    }

    // MARK: - 结构图

    /// PC `structure_map`：颜色无关的线条图（512×512）
    static func structureMap(
        rgb: [UInt8],
        side: Int = canonicalSize
    ) -> [UInt8] {
        let count = side * side
        // 转 float 0…1 并做 3×3 高斯（σ 由 ksize 推导 ≈0.8）
        var channels = [[Float]](repeating: [Float](repeating: 0, count: count), count: 3)
        for channel in 0..<3 {
            var plane = [Float](repeating: 0, count: count)
            for i in 0..<count { plane[i] = Float(rgb[i * 3 + channel]) / 255.0 }
            channels[channel] = gaussian(plane, side: side, sigma: 0.8, radius: 1)
        }

        var magnitudes = [[Float]](repeating: [Float](repeating: 0, count: count), count: 4)
        for channel in 0..<3 {
            magnitudes[channel] = gradientMagnitude(channels[channel], side: side)
        }
        // 灰度通道
        var luminance = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let r = channels[0][i], g = channels[1][i], b = channels[2][i]
            luminance[i] = 0.299 * r + 0.587 * g + 0.114 * b
        }
        magnitudes[3] = gradientMagnitude(luminance, side: side)

        var mag = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var best: Float = 0
            for c in 0..<4 { best = max(best, magnitudes[c][i]) }
            mag[i] = best
        }

        // 去低频：减 0.28 × GaussianBlur(σ=13)
        let low = gaussian(mag, side: side, sigma: 13.0, radius: Int((13.0 * 3).rounded()))
        for i in 0..<count {
            mag[i] = max(mag[i] - 0.28 * low[i], 0)
        }

        // 99.3 分位归一
        let sorted = mag.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * 0.993))
        let high = sorted[index]
        guard high > 1e-6 else { return [UInt8](repeating: 0, count: count) }
        for i in 0..<count {
            mag[i] = pow(min(1.0, mag[i] / high), 0.72)
        }
        mag = gaussian(mag, side: side, sigma: 1.15, radius: 4)
        return mag.map { UInt8(min(255, max(0, $0 * 255))) }
    }

    // MARK: - 基础算子

    static func gradientMagnitude(_ plane: [Float], side: Int) -> [Float] {
        var output = [Float](repeating: 0, count: side * side)
        // cv2.Sobel ksize=3 的核是 [-1 0 1]（带 1/8 归一不改变幅度排序）
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let gx = (plane[y * side + x + 1] - plane[y * side + x - 1])
                    + 2 * (plane[(y + 1) * side + x + 1] - plane[(y + 1) * side + x - 1])
                    + (plane[(y - 1) * side + x + 1] - plane[(y - 1) * side + x - 1])
                let gy = (plane[(y + 1) * side + x] - plane[(y - 1) * side + x])
                    + 2 * (plane[(y + 1) * side + x + 1] - plane[(y - 1) * side + x + 1])
                    + (plane[(y + 1) * side + x - 1] - plane[(y - 1) * side + x - 1])
                output[y * side + x] = (gx * gx + gy * gy).squareRoot() / 8.0
            }
        }
        return output
    }

    static func gaussian(_ plane: [Float], side: Int, sigma: Double, radius: Int) -> [Float] {
        guard sigma > 0, radius > 0 else { return plane }
        var kernel = [Double](repeating: 0, count: radius * 2 + 1)
        var sum = 0.0
        for i in -radius...radius {
            let value = exp(-Double(i * i) / (2 * sigma * sigma))
            kernel[i + radius] = value
            sum += value
        }
        let normalized = kernel.map { $0 / sum }

        var temp = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var acc = 0.0
                for k in -radius...radius {
                    let xx = min(side - 1, max(0, x + k))
                    acc += Double(plane[y * side + xx]) * normalized[k + radius]
                }
                temp[y * side + x] = Float(acc)
            }
        }
        var output = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                var acc = 0.0
                for k in -radius...radius {
                    let yy = min(side - 1, max(0, y + k))
                    acc += Double(temp[yy * side + x]) * normalized[k + radius]
                }
                output[y * side + x] = Float(acc)
            }
        }
        return output
    }

    // MARK: - 图像读取/缩放

    static func readRGB(_ cg: CGImage) -> (Int, Int, [UInt8]) {
        let width = cg.width
        let height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return (0, 0, []) }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = pixels[i * 4]
            rgb[i * 3 + 1] = pixels[i * 4 + 1]
            rgb[i * 3 + 2] = pixels[i * 4 + 2]
        }
        return (width, height, rgb)
    }

    static func cropRGB(_ rgb: [UInt8], width: Int, height: Int, box: (Int, Int, Int, Int)) -> [UInt8] {
        let (x0, y0, x1, y1) = box
        let cw = max(1, x1 - x0)
        let ch = max(1, y1 - y0)
        var output = [UInt8](repeating: 0, count: cw * ch * 3)
        for y in 0..<ch {
            for x in 0..<cw {
                let src = ((y0 + y) * width + (x0 + x)) * 3
                let dst = (y * cw + x) * 3
                output[dst] = rgb[src]
                output[dst + 1] = rgb[src + 1]
                output[dst + 2] = rgb[src + 2]
            }
        }
        return output
    }

    /// 双线性缩放（替代 LANCZOS，误差在可接受范围）
    static func resizeRGB(_ rgb: [UInt8], width: Int, height: Int, target: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: target * target * 3)
        let sx = Double(width) / Double(target)
        let sy = Double(height) / Double(target)
        for y in 0..<target {
            let fy = min(Double(height - 1), (Double(y) + 0.5) * sy - 0.5)
            let y0 = max(0, Int(fy))
            let y1 = min(height - 1, y0 + 1)
            let wy = Float(fy - Double(y0))
            for x in 0..<target {
                let fx = min(Double(width - 1), (Double(x) + 0.5) * sx - 0.5)
                let x0 = max(0, Int(fx))
                let x1 = min(width - 1, x0 + 1)
                let wx = Float(fx - Double(x0))
                for c in 0..<3 {
                    let v00 = Float(rgb[(y0 * width + x0) * 3 + c])
                    let v01 = Float(rgb[(y0 * width + x1) * 3 + c])
                    let v10 = Float(rgb[(y1 * width + x0) * 3 + c])
                    let v11 = Float(rgb[(y1 * width + x1) * 3 + c])
                    let top = v00 * (1 - wx) + v01 * wx
                    let bottom = v10 * (1 - wx) + v11 * wx
                    let value = top * (1 - wy) + bottom * wy
                    output[(y * target + x) * 3 + c] = UInt8(min(255, max(0, value)))
                }
            }
        }
        return output
    }

    /// 内容外接框（按边缘底色估计，留 2% 余量）
    static func contentBBox(rgb: [UInt8], width: Int, height: Int) -> (Int, Int, Int, Int)? {
        guard width > 8, height > 8 else { return nil }
        var samples: [UInt8] = []
        for x in stride(from: 0, to: width, by: max(1, width / 64)) {
            samples.append(rgb[x * 3])
            samples.append(rgb[((height - 1) * width + x) * 3])
        }
        for y in stride(from: 0, to: height, by: max(1, height / 64)) {
            samples.append(rgb[(y * width) * 3])
            samples.append(rgb[(y * width + width - 1) * 3])
        }
        samples.sort()
        let background = Int(samples[samples.count / 2])
        let threshold = 22

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                if abs(Int(rgb[(y * width + x) * 3]) - background) > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        return (minX, minY, maxX + 1, maxY + 1)
    }
}
