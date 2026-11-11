import Foundation
import UIKit
import CoreGraphics
import ImageIO

/// 图像基础操作：解码、灰度、CLAHE、旋转、镜像、裁切缩放。
///
/// 与 PC 一致的顺序（`ai_features._prepare`）：
///   EXIF → RGB → 灰度(L) → CLAHE(2.0, 8×8) → 复制成 RGB → 中心裁切 → BICUBIC 224 → 归一化
enum ImageOps {
    /// 解码成灰度（已做 CLAHE），返回宽高 + 像素
    static func loadEnhancedGray(from url: URL) throws -> PilImaging.GrayImage {
        let raw = try PilImaging.loadGray(from: url)
        let enhanced = Clahe.apply(raw.pixels, width: raw.width, height: raw.height)
        return PilImaging.GrayImage(width: raw.width, height: raw.height, pixels: enhanced)
    }

    /// 从已增强的灰度图里取一个旋转副本（角度为 0/45/…/315）
    /// 非 90 倍数的角度用旋转后外接矩形，空白填 255（白）
    static func rotate(
        _ image: PilImaging.GrayImage,
        degrees: Int
    ) -> PilImaging.GrayImage {
        let normalized = ((degrees % 360) + 360) % 360
        switch normalized {
        case 0:
            return image
        case 90:
            return rotateQuarter(image, times: 1)
        case 180:
            return rotateQuarter(image, times: 2)
        case 270:
            return rotateQuarter(image, times: 3)
        default:
            return rotateArbitrary(image, degrees: Double(normalized))
        }
    }

    static func mirror(_ image: PilImaging.GrayImage) -> PilImaging.GrayImage {
        var output = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            let row = y * image.width
            for x in 0..<image.width {
                output[row + x] = image.pixels[row + (image.width - 1 - x)]
            }
        }
        return PilImaging.GrayImage(width: image.width, height: image.height, pixels: output)
    }

    /// 逆时针旋转 90° × times
    private static func rotateQuarter(_ image: PilImaging.GrayImage, times: Int) -> PilImaging.GrayImage {
        var current = image
        for _ in 0..<times {
            let w = current.width
            let h = current.height
            var output = [UInt8](repeating: 0, count: w * h)
            // 逆时针：dst(x,y) = src(w-1-y, x)
            for y in 0..<w {
                for x in 0..<h {
                    output[y * h + x] = current.pixels[x * w + (w - 1 - y)]
                }
            }
            current = PilImaging.GrayImage(width: h, height: w, pixels: output)
        }
        return current
    }

    /// 任意角旋转（最近邻 + 白底），用于 45/135/225/315
    private static func rotateArbitrary(
        _ image: PilImaging.GrayImage,
        degrees: Double
    ) -> PilImaging.GrayImage {
        let radians = degrees * Double.pi / 180
        let cosA = cos(radians)
        let sinA = sin(radians)
        let w = Double(image.width)
        let h = Double(image.height)
        let newW = Int(ceil(abs(w * cosA) + abs(h * sinA)))
        let newH = Int(ceil(abs(w * sinA) + abs(h * cosA)))
        var output = [UInt8](repeating: 255, count: max(1, newW * newH))
        let cx = w / 2
        let cy = h / 2
        let ncx = Double(newW) / 2
        let ncy = Double(newH) / 2

        for y in 0..<newH {
            for x in 0..<newW {
                let dx = Double(x) - ncx
                let dy = Double(y) - ncy
                let sx = dx * cosA + dy * sinA + cx
                let sy = -dx * sinA + dy * cosA + cy
                let ix = Int(sx.rounded())
                let iy = Int(sy.rounded())
                if ix >= 0, ix < image.width, iy >= 0, iy < image.height {
                    output[y * newW + x] = image.pixels[iy * image.width + ix]
                }
            }
        }
        return PilImaging.GrayImage(width: newW, height: newH, pixels: output)
    }

    /// 自动裁切主体：裁掉四周的空白/纯色背景（安卓「自动裁切主体」）。
    /// 做法：以边缘像素的中位色当背景色，找出与之差异明显的内容外接框，留 3% 余量。
    static func autoCropSubject(_ image: PilImaging.GrayImage) -> PilImaging.GrayImage {
        let w = image.width
        let h = image.height
        guard w > 32, h > 32 else { return image }

        // 估计背景灰度：四条边采样取中位数
        var borderSamples: [UInt8] = []
        borderSamples.reserveCapacity(4 * 128)
        for x in stride(from: 0, to: w, by: max(1, w / 64)) {
            borderSamples.append(image.pixels[x])
            borderSamples.append(image.pixels[(h - 1) * w + x])
        }
        for y in stride(from: 0, to: h, by: max(1, h / 64)) {
            borderSamples.append(image.pixels[y * w])
            borderSamples.append(image.pixels[y * w + (w - 1)])
        }
        borderSamples.sort()
        let background = Int(borderSamples[borderSamples.count / 2])
        let threshold = 28

        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                if abs(Int(image.pixels[row + x]) - background) > threshold {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX > minX, maxY > minY else { return image }

        // 留 3% 余量，且至少 64px，避免裁得过紧
        let marginX = max(8, Int(Double(maxX - minX) * 0.03))
        let marginY = max(8, Int(Double(maxY - minY) * 0.03))
        let left = max(0, minX - marginX)
        let top = max(0, minY - marginY)
        let right = min(w, maxX + marginX)
        let bottom = min(h, maxY + marginY)

        let cropW = right - left
        let cropH = bottom - top
        guard cropW >= 64, cropH >= 64, cropW * cropH < w * h else { return image }

        var output = [UInt8](repeating: 0, count: cropW * cropH)
        for y in 0..<cropH {
            let src = (top + y) * w + left
            for x in 0..<cropW { output[y * cropW + x] = image.pixels[src + x] }
        }
        return PilImaging.GrayImage(width: cropW, height: cropH, pixels: output)
    }

    /// 按角度旋转 UIImage（给 SIFT 多旋转变体用）
    static func rotateUIImage(_ image: UIImage, degrees: Int) -> UIImage {
        let radians = CGFloat(degrees) * .pi / 180
        let width = image.size.width
        let height = image.size.height
        let rotatedSize = CGRect(origin: .zero, size: CGSize(width: width, height: height))
            .applying(CGAffineTransform(rotationAngle: radians)).size
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: rotatedSize, format: format)
        return renderer.image { context in
            let cg = context.cgContext
            cg.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            cg.rotate(by: radians)
            image.draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }
    }

    /// 导出 RGBA8 字节（给 OpenCV 用）
    static func rgbaBytes(_ image: UIImage, maxSide: Int = 900) -> (data: Data, width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let longest = max(cg.width, cg.height)
        let scale = longest > maxSide ? Double(maxSide) / Double(longest) : 1.0
        let width = max(1, Int(Double(cg.width) * scale))
        let height = max(1, Int(Double(cg.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (Data(pixels), width, height)
    }

    enum BandSide { case top, bottom, left, right }

    /// 取一条边带（用于序列花型的条带匹配）
    static func cropBand(
        _ image: PilImaging.GrayImage,
        fraction: Double,
        side: BandSide
    ) -> PilImaging.GrayImage {
        let w = image.width
        let h = image.height
        let horizontal = (side == .top || side == .bottom)
        let thickness = max(16, Int(Double(horizontal ? h : w) * fraction))
        let x0 = side == .left ? 0 : (side == .right ? max(0, w - thickness) : 0)
        let y0 = side == .top ? 0 : (side == .bottom ? max(0, h - thickness) : 0)
        let cw = horizontal ? w : thickness
        let ch = horizontal ? thickness : h
        var out = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let src = (y0 + y) * w + x0
            for x in 0..<cw { out[y * cw + x] = image.pixels[src + x] }
        }
        return PilImaging.GrayImage(width: cw, height: ch, pixels: out)
    }

    /// 中心方形裁切 + BICUBIC 缩放到 size，再归一化成 NCHW 张量
    static func prepareTensor(
        _ image: PilImaging.GrayImage,
        fraction: Double,
        size: Int = 224
    ) -> [Float] {
        let cropped = PilImaging.centerCrop(image, fraction: fraction)
        let resized = PilImaging.resizeBicubic(cropped, width: size, height: size)
        return PilImaging.toTensor(resized)
    }

    /// 生成 3×3 tile 的九张裁切张量（每块缩放到 size）
    static func prepareTiles(
        _ image: PilImaging.GrayImage,
        size: Int = 224
    ) -> [[Float]] {
        var tiles: [[Float]] = []
        let w = image.width
        let h = image.height
        let tw = w / 3
        let th = h / 3
        for ty in 0..<3 {
            for tx in 0..<3 {
                let x0 = tx * tw
                let y0 = ty * th
                let width = min(tw, w - x0)
                let height = min(th, h - y0)
                guard width > 8, height > 8 else { continue }
                var pixels = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let src = (y0 + y) * w + x0
                    for x in 0..<width {
                        pixels[y * width + x] = image.pixels[src + x]
                    }
                }
                let tile = PilImaging.GrayImage(width: width, height: height, pixels: pixels)
                let resized = PilImaging.resizeBicubic(tile, width: size, height: size)
                tiles.append(PilImaging.toTensor(resized))
            }
        }
        return tiles
    }
}
