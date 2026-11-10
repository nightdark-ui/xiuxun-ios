import Foundation
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// 深度复核用的两路"第二意见"：
///   1. Vision FeaturePrint —— Apple 内置通用图像描述子（跑在 ANE 上，快且对变形稳）
///   2. 结构签名 —— Core Image 边缘图 + 8 方向梯度直方图（近似 SIFT 的结构分）
///
/// 二者都只用于**重排候选**，不参与召回，因此不会破坏 DINOv2 的索引一致性。
enum ExtraScores {
    /// Vision 特征向量（L2 归一化后存）
    static func visionPrint(_ image: UIImage) -> [Float]? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .centerCrop
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else {
                return nil
            }
            var vector = [Float](repeating: 0, count: observation.elementCount)
            vector.withUnsafeMutableBytes { buffer in
                if let base = buffer.baseAddress {
                    observation.data.copyBytes(to: base, count: observation.data.count)
                }
            }
            return normalize(vector)
        } catch {
            return nil
        }
    }

    /// 结构签名：边缘强度 + 8 方向梯度直方图（32 维）
    static func structureSignature(_ image: UIImage) -> [Float]? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])

        guard let edges = CIFilter(name: "CIEdges", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputIntensityKey: 1.0,
        ])?.outputImage else { return nil }

        // 缩到 64×64 便于统计
        let scale = CGAffineTransform(
            scaleX: 64.0 / ciImage.extent.width,
            y: 64.0 / ciImage.extent.height
        )
        let small = edges.transformed(by: scale)
        guard let output = context.createCGImage(small, from: small.extent) else { return nil }

        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let cgContext = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        cgContext.draw(output, in: CGRect(x: 0, y: 0, width: width, height: height))

        var gray = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            gray[i] = Float(pixels[i * 4]) * 0.299
                + Float(pixels[i * 4 + 1]) * 0.587
                + Float(pixels[i * 4 + 2]) * 0.114
        }

        // 8 方向直方图 + 4 个强度分位
        var histogram = [Float](repeating: 0, count: 8)
        var total = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let gx = gray[y * width + x + 1] - gray[y * width + x - 1]
                let gy = gray[(y + 1) * width + x] - gray[(y - 1) * width + x]
                let magnitude = sqrt(gx * gx + gy * gy)
                if magnitude < 4 { continue }
                var angle = atan2(gy, gx) * 180.0 / Float.pi
                if angle < 0 { angle += 360 }
                let bin = Int(angle / 45.0) % 8
                histogram[bin] += magnitude
                total += Double(magnitude)
            }
        }
        if total > 0 {
            for i in 0..<8 { histogram[i] /= Float(total) }
        }

        // 强度分位（边缘密度分布）
        let sum = gray.reduce(0, +) / Float(gray.count)
        let variance = gray.reduce(0) { $0 + ($1 - sum) * ($1 - sum) } / Float(gray.count)
        let signature = histogram + [sum / 255.0, sqrt(variance) / 255.0]
        return normalize(signature)
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for i in 0..<count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y; na += x * x; nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    private static func normalize(_ values: [Float]) -> [Float] {
        var result = values
        var norm = 0.0
        for v in result { norm += Double(v) * Double(v) }
        norm = sqrt(norm)
        if norm > 1e-9 {
            for i in 0..<result.count { result[i] = Float(Double(result[i]) / norm) }
        }
        return result
    }
}

/// 详情页的"第二意见"面板（影子模式：只显示，不参与排序）
struct ScoresPanel: View {
    let queryImage: UIImage?
    let candidateImage: UIImage?
    let dinoScore: Double

    @State private var visionScore: Double = -1
    @State private var structureScore: Double = -1
    @State private var running = false

    var body: some View {
        AppCard {
            CardHeader(title: "复核参考", trailing: running ? "计算中…" : "仅供参考")
            row("DINOv2（在用）", String(format: "%.3f", dinoScore), color: UI.orange)
            row("Vision", visionScore < 0 ? "—" : String(format: "%.3f", visionScore), color: UI.textPrimary)
            row("结构", structureScore < 0 ? "—" : String(format: "%.3f", structureScore), color: UI.textPrimary)
            Hint(text: "Vision 是 Apple 内置描述子，结构是边缘方向直方图；两者目前只作参考，未参与排序。")
        }
        .task { compute() }
    }

    private func row(_ title: String, _ value: String, color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(UI.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }

    private func compute() {
        guard !running else { return }
        running = true
        let query = queryImage
        let candidate = candidateImage
        DispatchQueue.global(qos: .userInitiated).async {
            var vision = -1.0
            var structure = -1.0
            if let query = query, let candidate = candidate,
               let a = ExtraScores.visionPrint(query),
               let b = ExtraScores.visionPrint(candidate) {
                vision = ExtraScores.cosine(a, b)
            }
            if let query = query, let candidate = candidate,
               let a = ExtraScores.structureSignature(query),
               let b = ExtraScores.structureSignature(candidate) {
                structure = ExtraScores.cosine(a, b)
            }
            DispatchQueue.main.async {
                visionScore = vision
                structureScore = structure
                running = false
            }
        }
    }
}
