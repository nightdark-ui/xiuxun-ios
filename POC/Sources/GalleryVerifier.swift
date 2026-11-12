import Foundation

/// 图库完整性校验（手动触发）。
/// 检查：款数、recall.bin 大小、heavy.bin 覆盖范围、图片与缩略图是否齐全、base 模型是否存在。
struct GalleryReport {
    var designs: Int = 0
    var recallOK = false
    var heavyOK = false
    var baseModelOK = false
    var recallActualMB: Double = 0
    var recallExpectedMB: Double = 0
    var heavyActualMB: Double = 0
    var uniqueCodes: Int = 0
    var versionOK = true
    var versionMessage = ""
    var missingImages: [String] = []
    var missingThumbs: [String] = []
    var checkedImages = 0

    var summary: String {
        var lines: [String] = []
        lines.append("款数：\(designs) 条记录 / \(uniqueCodes) 个款号")
        lines.append(String(format: "recall.bin：%.1f MB（应为 %.1f MB）%@",
                            recallActualMB, recallExpectedMB, recallOK ? " ✅" : " ❌"))
        lines.append(String(format: "heavy.bin：%.1f MB%@", heavyActualMB, heavyOK ? " ✅" : " ❌"))
        if !versionOK { lines.append("版本：\(versionMessage)") }
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
        let expected = Int64(package.count * GalleryPackage.recallBytes)
        report.recallExpectedMB = Double(expected) / 1024 / 1024
        if let size = fileSize(recallURL) {
            report.recallActualMB = Double(size) / 1024 / 1024
            report.recallOK = size == expected
        }

        // 款号去重统计（一款多图时记录数 > 款号数）
        var codes = Set<String>()
        for design in package.designs { codes.insert(design.code) }
        report.uniqueCodes = codes.count

        // 版本校验
        let version = GalleryVersionCheck.validate(indexURL: root.appendingPathComponent("index.json"))
        report.versionOK = version.ok
        report.versionMessage = version.message

        // heavy.bin：最后一款的偏移必须落在文件内
        let heavyURL = root.appendingPathComponent("heavy.bin")
        if let size = fileSize(heavyURL), let last = package.designs.last {
            report.heavyActualMB = Double(size) / 1024 / 1024
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
