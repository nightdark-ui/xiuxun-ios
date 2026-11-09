import Foundation
import CoreGraphics
import ImageIO

/// 图像基础操作：解码、灰度、CLAHE、旋转、镜像、裁切缩放。
///
/// 与 PC 一致的顺序（`ai_features._prepare`）：
///   EXIF → RGB → 灰度(L) → CLAHE(2.0, 8×8) → 复制成 RGB → 中心裁切 → BICUBIC 224 → 归一化
enum ImageOps {
    /// 解码成灰度（已做 CLAHE），返回宽高 + 像素
    static func loadEnhancedGray(from url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let raw = try PilImaging.loadGray(from: url)
        let enhanced = Clahe.apply(raw.pixels, width: raw.width, height: raw.height)
        return (raw.width, raw.height, enhanced)
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
                    pixels[y * width + x] = 0
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
