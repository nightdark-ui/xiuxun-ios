import Foundation
import CoreGraphics
import ImageIO

/// 与 PC（Python + Pillow + OpenCV）对齐的图像预处理。
///
/// 本文件只做 v3a 的部分：
///   1. 解码 JPEG（不做 EXIF 旋转，POC 用的图没有方向标记）
///   2. 转灰度（PIL 的 L 通道公式：19595/38470/7471 定点）
///   3. 中心方形裁切（fraction = 1.0）
///   4. BICUBIC 缩放到 224×224（Pillow 语义：下采样时按 in/out 放大 support）
///   5. (v/255 - mean) / std，输出 NCHW
///
/// CLAHE 不在这里做：它必须由 OpenCV 执行才能逐位一致，留到接 OpenCV 时补。
enum PilImaging {

    struct GrayImage {
        let width: Int
        let height: Int
        var pixels: [UInt8]
    }

    // ---------------- 解码 ----------------

    static func loadGray(from url: URL) throws -> GrayImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProbeError.badInput("图片解码失败：\(url.lastPathComponent)")
        }
        return try gray(from: cgImage)
    }

    static func gray(from cgImage: CGImage) throws -> GrayImage {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw ProbeError.badInput("图片尺寸为 0") }

        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        // noneSkipLast：不预乘 alpha，保持原始 RGB 值
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(
            data: &rgba,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw ProbeError.badInput("无法创建绘图上下文")
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // PIL 的 convert("L")：L = (r*19595 + g*38470 + b*7471 + 32768) >> 16
        var grayPixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(rgba[i * 4])
            let g = Int(rgba[i * 4 + 1])
            let b = Int(rgba[i * 4 + 2])
            let value = (r * 19595 + g * 38470 + b * 7471 + 32768) >> 16
            grayPixels[i] = UInt8(min(255, max(0, value)))
        }
        return GrayImage(width: width, height: height, pixels: grayPixels)
    }

    // ---------------- 裁切 ----------------

    static func centerCrop(_ image: GrayImage, fraction: Double) -> GrayImage {
        let side = max(32, Int(Double(min(image.width, image.height)) * fraction))
        let left = (image.width - side) / 2
        let top = (image.height - side) / 2
        var output = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            let srcRow = (top + y) * image.width + left
            for x in 0..<side {
                output[y * side + x] = image.pixels[srcRow + x]
            }
        }
        return GrayImage(width: side, height: side, pixels: output)
    }

    // ---------------- BICUBIC 缩放（Pillow 语义） ----------------

    private static let a = -0.5

    private static func bicubic(_ x: Double) -> Double {
        let x = abs(x)
        if x <= 1.0 {
            return ((a + 2.0) * x - (a + 3.0)) * x * x + 1.0
        } else if x < 2.0 {
            return (((x - 5.0) * x + 8.0) * x - 4.0) * a
        }
        return 0.0
    }

    /// 一维权重表：下采样时 support 会按 in/out 放大（Pillow 的抗锯齿行为）
    private static func coefficients(inSize: Int, outSize: Int) -> (support: Int, bounds: [(Int, Int)], weights: [[Double]]) {
        let scale = Double(inSize) / Double(outSize)
        var filterscale = 1.0
        var support = 2.0
        if scale > 1.0 {
            filterscale = scale
            support *= filterscale
        }
        let supportInt = Int(ceil(support))
        var bounds: [(Int, Int)] = []
        var weights: [[Double]] = []
        for out in 0..<outSize {
            let center = (Double(out) + 0.5) * scale
            var xmin = Int(floor(center - support))
            var xmax = Int(ceil(center + support))
            xmin = max(0, xmin)
            xmax = min(inSize, xmax)
            if xmax <= xmin { xmax = min(inSize, xmin + 1) }
            var row: [Double] = []
            var sum = 0.0
            for x in xmin..<xmax {
                let w = bicubic((Double(x) + 0.5 - center) / filterscale)
                row.append(w)
                sum += w
            }
            if sum != 0 {
                for i in 0..<row.count { row[i] /= sum }
            }
            bounds.append((xmin, xmax))
            weights.append(row)
        }
        return (supportInt, bounds, weights)
    }

    static func resizeBicubic(_ image: GrayImage, width outW: Int, height outH: Int) -> GrayImage {
        // 横向
        let horizontal = coefficients(inSize: image.width, outSize: outW)
        var temp = [Double](repeating: 0, count: outW * image.height)
        for y in 0..<image.height {
            let srcRow = y * image.width
            for x in 0..<outW {
                let (xmin, _) = horizontal.bounds[x]
                let row = horizontal.weights[x]
                var sum = 0.0
                for (i, w) in row.enumerated() {
                    sum += w * Double(image.pixels[srcRow + xmin + i])
                }
                temp[y * outW + x] = sum
            }
        }

        // 纵向
        let vertical = coefficients(inSize: image.height, outSize: outH)
        var output = [UInt8](repeating: 0, count: outW * outH)
        for y in 0..<outH {
            let (ymin, _) = vertical.bounds[y]
            let row = vertical.weights[y]
            for x in 0..<outW {
                var sum = 0.0
                for (i, w) in row.enumerated() {
                    sum += w * temp[(ymin + i) * outW + x]
                }
                let rounded = Int(sum + 0.5)
                output[y * outW + x] = UInt8(min(255, max(0, rounded)))
            }
        }
        return GrayImage(width: outW, height: outH, pixels: output)
    }

    // ---------------- 归一化 ----------------

    private static let mean: [Double] = [0.485, 0.456, 0.406]
    private static let std: [Double] = [0.229, 0.224, 0.225]

    /// 灰度图 → NCHW float32（三个通道相同，因为 PC 也是灰度复制成 RGB）
    static func toTensor(_ image: GrayImage) -> [Float] {
        let count = image.width * image.height
        var tensor = [Float](repeating: 0, count: count * 3)
        for channel in 0..<3 {
            let m = mean[channel]
            let s = std[channel]
            for i in 0..<count {
                let value = Double(image.pixels[i]) / 255.0
                tensor[channel * count + i] = Float((value - m) / s)
            }
        }
        return tensor
    }

    /// 完整流程：JPEG → 张量
    static func prepareTensor(
        from url: URL,
        size: Int = 224,
        fraction: Double = 1.0
    ) throws -> (tensor: [Float], resized: GrayImage, gray: GrayImage) {
        let gray = try loadGray(from: url)
        let cropped = centerCrop(gray, fraction: fraction)
        let resized = resizeBicubic(cropped, width: size, height: size)
        let tensor = toTensor(resized)
        return (tensor, resized, gray)
    }
}
