import Foundation

/// 图库完整性校验（手动触发）。
/// 检查：款数、recall.bin 大小、heavy.bin 覆盖范围、图片与缩略图是否齐全、base 模型是否存在。
struct GalleryReport {
    var designs: Int = 0
    var recallOK = false
    var heavyOK = false
    var baseModelOK = false
    var missingImages: [String] = []
    var missingThumbs: [String] = []
    var checkedImages = 0

    var summary: String {
        var lines: [String] = []
        lines.append("款数：\(designs)")
        lines.append("recall.bin：\(recallOK ? "正常" : "异常")")
        lines.append("heavy.bin：\(heavyOK ? "正常" : "异常")")
        lines.append("base 模型：\(baseModelOK ? "已就位" : "缺失（深度复排不可用）")")
        if missingImages.isEmpty && missingThumbs.isEmpty {
            lines.append("图片 / 缩略图：全部齐全（检查 \(checkedImages) 张）")
        } else {
            if !missingImages.isEmpty {
                lines.append("缺原图 \(missingImages.count) 张，例如：\(missingImages.prefix(3).joined(separator: "、"))")
            }
            if !missingThumbs.isEmpty {
                lines.append("缺缩略图 \(missingThumbs.count) 张，例如：\(missingThumbs.prefix(3).joined(separator: "、"))")
            }
        }
        return lines.joined(separator: "\n")
    }
}

enum GalleryVerifier {
    static func verify(_ package: GalleryPackage, progress: (String) -> Void = { _ in }) -> GalleryReport {
        var report = GalleryReport()
        let fileManager = FileManager.default
        let root = package.root
        report.designs = package.count

        // recall.bin 大小
        let recallURL = root.appendingPathComponent("recall.bin")
        if let size = fileSize(recallURL) {
            report.recallOK = size == Int64(package.count * GalleryPackage.recallBytes)
        }

        // heavy.bin：最后一款的偏移必须落在文件内
        let heavyURL = root.appendingPathComponent("heavy.bin")
        if let size = fileSize(heavyURL), let last = package.designs.last {
            report.heavyOK = size > last.heavyOffset
        }

        // base 模型：先看 App 内置（IPA 里），再看图库目录
        if DinoEncoder.resolveModelURL(variant: .base) != nil {
            report.baseModelOK = true
        } else {
            let local = root.appendingPathComponent("models/dinov2-base-fp16.onnx")
            report.baseModelOK = fileManager.fileExists(atPath: local.path)
        }

        // 图片 / 缩略图（抽样全量存在性检查，不打开文件）
        progress("校验图片…")
        for design in package.designs {
            report.checkedImages += 1
            if !fileManager.fileExists(atPath: package.imageURL(for: design).path) {
                if report.missingImages.count < 50 { report.missingImages.append(design.image) }
            }
            if !fileManager.fileExists(atPath: package.thumbURL(for: design).path) {
                if report.missingThumbs.count < 50 { report.missingThumbs.append(design.image) }
            }
        }
        return report
    }

    private static func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let number = attributes[.size] as? NSNumber else { return nil }
        return number.int64Value
    }
}
