import Foundation
import CoreGraphics
import ImageIO

/// 与 PC（Python + Pillow + OpenCV）对齐的图像预处理（v3a）。
///
/// 崩溃排查辅助：每个阶段开始前会把阶段名写进 UserDefaults，
/// 即使进程崩溃，下次启动也能看到"上次跑到哪一步"。
enum ProbeStep: String {
    case start = "开始"
    case decode = "解码图片"
    case gray = "转灰度"
    case crop = "裁切"
    case resize = "BICUBIC 缩放"
    case tensor = "归一化"
    case loadSession = "加载模型"
    case buildTensor = "构造张量"
    case runReference = "跑参考张量"
    case runOurs = "跑自算张量"
    case runSession = "session.run"
    case readOutput = "读取输出"
    case runModel = "模型推理"
    case done = "完成"
}

enum ProbeTrace {
    private static let key = "probe.lastStep"

    static func mark(_ step: ProbeStep) {
        UserDefaults.standard.set(step.rawValue, forKey: key)
        UserDefaults.standard.synchronize()
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    static var last: String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    private static let noteKey = "probe.note"

    static func note(_ text: String) {
        UserDefaults.standard.set(text, forKey: noteKey)
        UserDefaults.standard.synchronize()
    }

    static var lastNote: String {
        UserDefaults.standard.string(forKey: noteKey) ?? ""
    }

    static func clearNote() {
        UserDefaults.standard.removeObject(forKey: noteKey)
    }
}

enum PilImaging {

    struct GrayImage {
        let width: Int
        let height: Int
        var pixels: [UInt8]
    }

    // ---------------- 解码 ----------------

    static func loadGray(from url: URL) throws -> GrayImage {
        ProbeTrace.mark(.decode)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ProbeError.badInput("图片解码失败：\(url.lastPathComponent)")
        }
        return try gray(from: cgImage)
    }

    static func gray(from cgImage: CGImage) throws -> GrayImage {
        ProbeTrace.mark(.gray)
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw ProbeError.badInput("图片尺寸为 0") }

        let byteCount = width * height * 4
        var rgba = [UInt8](repeating: 0, count: byteCount)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        // 用 withUnsafeMutableBytes 拿到稳定的缓冲区指针（比传 &array 安全）
        let ok: Bool = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            guard let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw ProbeError.badInput("无法创建绘图上下文") }

        var grayPixels = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let base = i * 4
            let r = Int(rgba[base])
            let g = Int(rgba[base + 1])
            let b = Int(rgba[base + 2])
            let value = (r * 19595 + g * 38470 + b * 7471 + 32768) >> 16
            grayPixels[i] = UInt8(min(255, max(0, value)))
        }
        return GrayImage(width: width, height: height, pixels: grayPixels)
    }

    // ---------------- 裁切 ----------------

    static func centerCrop(_ image: GrayImage, fraction: Double) -> GrayImage {
        ProbeTrace.mark(.crop)
        let shortSide = min(image.width, image.height)
        let scaled = Double(shortSide) * fraction
        var side = Int(scaled.isFinite ? scaled.rounded() : Double(shortSide))
        side = max(1, min(side, shortSide))
        let left = max(0, min((image.width - side) / 2, image.width - side))
        let top = max(0, min((image.height - side) / 2, image.height - side))

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
        let value = abs(x)
        if value <= 1.0 {
            return ((a + 2.0) * value - (a + 3.0)) * value * value + 1.0
        } else if value < 2.0 {
            return (((value - 5.0) * value + 8.0) * value - 4.0) * a
        }
        return 0.0
    }

    private struct Axis {
        var starts: [Int] = []
        var weights: [[Double]] = []
    }

    private static func coefficients(inSize: Int, outSize: Int) -> Axis {
        let inS = max(1, inSize)
        let outS = max(1, outSize)
        let scale = Double(inS) / Double(outS)
        var filterScale = 1.0
        var support = 2.0
        if scale > 1.0 {
            filterScale = scale
            support *= filterScale
        }
        var axis = Axis()
        for out in 0..<outS {
            let center = (Double(out) + 0.5) * scale
            var xmin = Int((center - support).rounded(.down))
            var xmax = Int((center + support).rounded(.up))
            xmin = max(0, min(xmin, inS - 1))
            xmax = max(xmin + 1, min(xmax, inS))
            var row: [Double] = []
            row.reserveCapacity(xmax - xmin)
            var sum = 0.0
            for x in xmin..<xmax {
                let w = bicubic((Double(x) + 0.5 - center) / filterScale)
                row.append(w)
                sum += w
            }
            if sum != 0 {
                for i in 0..<row.count { row[i] /= sum }
            }
            axis.starts.append(xmin)
            axis.weights.append(row)
        }
        return axis
    }

    static func resizeBicubic(_ image: GrayImage, width outW: Int, height outH: Int) -> GrayImage {
        ProbeTrace.mark(.resize)
        let outWidth = max(1, outW)
        let outHeight = max(1, outH)
        let horizontal = coefficients(inSize: image.width, outSize: outWidth)
        var temp = [Double](repeating: 0, count: outWidth * image.height)

        for y in 0..<image.height {
            let srcRow = y * image.width
            for x in 0..<outWidth {
                let start = horizontal.starts[x]
                let row = horizontal.weights[x]
                var sum = 0.0
                for (i, w) in row.enumerated() {
                    let index = srcRow + start + i
                    if index >= 0 && index < image.pixels.count {
                        sum += w * Double(image.pixels[index])
                    }
                }
                temp[y * outWidth + x] = sum
            }
        }

        let vertical = coefficients(inSize: image.height, outSize: outHeight)
        var output = [UInt8](repeating: 0, count: outWidth * outHeight)
        for y in 0..<outHeight {
            let start = vertical.starts[y]
            let row = vertical.weights[y]
            for x in 0..<outWidth {
                var sum = 0.0
                for (i, w) in row.enumerated() {
                    let index = (start + i) * outWidth + x
                    if index >= 0 && index < temp.count {
                        sum += w * temp[index]
                    }
                }
                let rounded = (sum + 0.5).rounded(.down)
                output[y * outWidth + x] = UInt8(min(255.0, max(0.0, rounded)))
            }
        }
        return GrayImage(width: outWidth, height: outHeight, pixels: output)
    }

    // ---------------- 归一化 ----------------

    private static let mean: [Double] = [0.485, 0.456, 0.406]
    private static let std: [Double] = [0.229, 0.224, 0.225]

    static func toTensor(_ image: GrayImage) -> [Float] {
        ProbeTrace.mark(.tensor)
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
