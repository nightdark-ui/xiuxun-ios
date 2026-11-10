import Foundation
import UIKit
import Vision

/// 轮廓匹配（替代 SIFT 的角色）：用 Apple 原生的 `VNDetectContoursRequest`
/// 提取查询图的线条骨架，与图库款的 80×80 边缘图比对。
///
/// 为什么用它替代 SIFT：
///   - 原生框架，跑在 GPU/ANE 上，比手写 SIFT 快且稳
///   - 刺绣花型本质是"线条图案"，轮廓比关键点更贴合
///   - 图库侧不需要新索引：复用 heavy.bin 里已有的 edge(80×80)
enum ContourScore {
    static let side = 80

    struct Descriptor {
        var mask: [Float]          // 80×80 轮廓栅格（0…1）
        var contourCount: Int
        var totalLength: Double    // 归一化总长度
        var meanCurvature: Double
        var bboxFill: Double       // 轮廓覆盖面积比例
    }

    /// 提取查询图轮廓（失败返回 nil）
    static func describe(_ image: UIImage) -> Descriptor? {
        guard let cgImage = image.cgImage else { return nil }
        let request = VNDetectContoursRequest()
        request.contrastAdjustment = 2.0
        request.detectsDarkOnLight = true
        request.maximumImageDimension = 512

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first as? VNContoursObservation else { return nil }

        var mask = [Float](repeating: 0, count: side * side)
        var totalLength = 0.0
        var curvatureSum = 0.0
        var curvatureCount = 0
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for contour in observation.topLevelContours {
            let points = contour.normalizedPoints
            guard points.count >= 2 else { continue }
            var previousX: Double?
            var previousY: Double?
            var previousAngle: Double?
            for point in points {
                let nx = Double(point.x)
                let ny = 1.0 - Double(point.y)   // Vision 以左下为原点
                minX = min(minX, nx); maxX = max(maxX, nx)
                minY = min(minY, ny); maxY = max(maxY, ny)

                let px = min(side - 1, max(0, Int(nx * Double(side))))
                let py = min(side - 1, max(0, Int(ny * Double(side))))
                mask[py * side + px] = 1.0

                if let lastX = previousX, let lastY = previousY {
                    let dx = nx - lastX
                    let dy = ny - lastY
                    totalLength += (dx * dx + dy * dy).squareRoot()
                    let angle = atan2(dy, dx)
                    if let lastAngle = previousAngle {
                        var delta = abs(angle - lastAngle)
                        if delta > Double.pi { delta = 2 * Double.pi - delta }
                        curvatureSum += delta
                        curvatureCount += 1
                    }
                    previousAngle = angle
                }
                previousX = nx
                previousY = ny
            }
        }

        // 轮廓膨胀一点，抵消栅格化稀疏
        var dilated = mask
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) where mask[y * side + x] > 0 {
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx
                    let ny = y + dy
                    if nx >= 0, nx < side, ny >= 0, ny < side {
                        dilated[ny * side + nx] = max(dilated[ny * side + nx], 0.6)
                    }
                }
            }
        }

        let bboxFill = (minX < maxX && minY < maxY)
            ? ((maxX - minX) * (maxY - minY))
            : 0

        return Descriptor(
            mask: dilated,
            contourCount: observation.contourCount,
            totalLength: totalLength,
            meanCurvature: curvatureCount > 0 ? curvatureSum / Double(curvatureCount) : 0,
            bboxFill: bboxFill
        )
    }

    /// 轮廓与图库边缘图的结构相似度（0…1）
    /// - Parameters:
    ///   - query: 查询轮廓描述子
    ///   - designEdge: heavy.bin 里的 80×80 边缘图（0…1）
    static func similarity(query: Descriptor, designEdge: [Float]) -> Double {
        guard designEdge.count >= side * side else { return 0 }

        // 1) 栅格相关（去均值余弦）
        let correlation = StructureScore.edgeCorrelation(query.mask, designEdge)

        // 2) 覆盖率接近度：轮廓像素占边缘像素的比例
        var designDensity = 0.0
        for value in designEdge where value > 0.25 { designDensity += 1 }
        designDensity /= Double(side * side)
        var queryDensity = 0.0
        for value in query.mask where value > 0.25 { queryDensity += 1 }
        queryDensity /= Double(side * side)
        let densityScore = 1.0 - min(1.0, abs(queryDensity - designDensity) / max(0.05, max(queryDensity, designDensity)))

        // 3) 曲率合理性：轮廓曲率越高越像刺绣曲线，过低（直线）说明可能不是花型
        let curvatureScore = min(1.0, query.meanCurvature / 0.35)

        return max(0, min(1, 0.70 * correlation + 0.20 * densityScore + 0.10 * curvatureScore))
    }
}
