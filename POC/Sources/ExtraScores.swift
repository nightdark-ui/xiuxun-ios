import Foundation
import SwiftUI
import UIKit
import Vision
import CoreImage

/// 深度复核用的两路"第二意见"：
///   1. Vision FeaturePrint —— Apple 内置通用描述子（ANE，快且对变形稳）
///   2. 结构签名 —— Core Image 边缘图 + 8 方向梯度直方图（近似 SIFT 的结构分）
/// 两者只用于**重排候选**，不参与召回，因此不破坏 DINOv2 索引一致性。
enum ExtraScores {

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
            let count = observation.elementCount
            guard count > 0 else { return nil }
            var vector = [Float](repeating: 0, count: count)
            observation.data.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: Float.self)
                for i in 0..<min(count, source.count) { vector[i] = source[i] }
            }
            return normalize(vector)
        } catch {
            return nil
        }
    }

    static func structureSignature(_ image: UIImage) -> [Float]? {
        guard let cgImage = image.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [:])

        guard let edges = CIFilter(name: "CIEdges", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputIntensityKey: 1.0,
        ])?.outputImage else { return nil }

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

        var histogram = [Float](repeating: 0, count: 8)
        var total: Float = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let gx = gray[y * width + x + 1] - gray[y * width + x - 1]
                let gy = gray[(y + 1) * width + x] - gray[(y - 1) * width + x]
                let magnitude = sqrt(gx * gx + gy * gy)
                if magnitude < 4 { continue }
                var angle = atan2(gy, gx) * 180.0 / Float.pi
                if angle < 0 { angle += 360 }
                let bin = min(7, Int(angle / 45.0))
                histogram[bin] += magnitude
                total += magnitude
            }
        }
        if total > 0 {
            for i in 0..<8 { histogram[i] /= total }
        }

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
            dot += x * y
            na += x * x
            nb += y * y
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

/// 复核状态（用 class 持有，避免 struct View 里的 @State 跨线程写入问题）
final class ScoresModel: ObservableObject {
    @Published var visionScore: Double = -1
    @Published var structureScore: Double = -1
    @Published var running = false

    func compute(query: UIImage?, candidate: UIImage?) {
        guard !running, let query = query, let candidate = candidate else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var vision = -1.0
            var structure = -1.0
            if let a = ExtraScores.visionPrint(query), let b = ExtraScores.visionPrint(candidate) {
                vision = ExtraScores.cosine(a, b)
            }
            if let a = ExtraScores.structureSignature(query),
               let b = ExtraScores.structureSignature(candidate) {
                structure = ExtraScores.cosine(a, b)
            }
            DispatchQueue.main.async {
                self?.visionScore = vision
                self?.structureScore = structure
                self?.running = false
            }
        }
    }
}

struct ScoresPanel: View {
    let queryImage: UIImage?
    let candidateImage: UIImage?
    let dinoScore: Double

    @StateObject private var model = ScoresModel()

    init(queryImage: UIImage?, candidateImage: UIImage?, dinoScore: Double) {
        self.queryImage = queryImage
        self.candidateImage = candidateImage
        self.dinoScore = dinoScore
    }

    var body: some View {
        AppCard {
            CardHeader(title: "复核参考", trailing: model.running ? "计算中…" : "仅供参考")
            row("DINOv2（在用）", String(format: "%.3f", dinoScore), UI.orange)
            row("Vision", model.visionScore < 0 ? "—" : String(format: "%.3f", model.visionScore), UI.textPrimary)
            row("结构", model.structureScore < 0 ? "—" : String(format: "%.3f", model.structureScore), UI.textPrimary)
            Hint(text: "Vision 是 Apple 内置描述子，结构是边缘方向直方图；目前只作参考，未参与排序。")
        }
        .onAppear { model.compute(query: queryImage, candidate: candidateImage) }
        .onChange(of: candidateImage) { image in
            model.compute(query: queryImage, candidate: image)
        }
    }

    private func row(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(UI.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
        }
    }
}
