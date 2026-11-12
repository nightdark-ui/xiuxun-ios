import Foundation

/// 图库包格式/特征版本校验。
///
/// 与 PC/安卓导出器约定的字段（index.json 顶层）：
///   format, format_version, embedding_version, feature_version,
///   cls_rows, tile_rows, dim, base_dim
///
/// 版本不匹配时**必须明确提示**，而不是默默用错特征给出错误结果。
enum GalleryVersionCheck {

    /// iOS 当前支持的版本
    static let supportedFormat = "xiuxun-android-index"
    static let supportedFormatVersion = 1
    static let supportedEmbeddingVersion = 1
    static let supportedFeatureVersion = 3
    static let supportedCLSRows = 5
    static let supportedTileRows = 9
    static let supportedDim = 384
    static let supportedBaseDim = 768

    struct Result {
        var ok: Bool
        var message: String
        var details: [String]
    }

    /// 校验 index.json 顶层的版本/维度字段
    static func validate(indexURL: URL) -> Result {
        guard let data = try? Data(contentsOf: indexURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Result(ok: false, message: "index.json 无法读取或格式错误", details: [])
        }

        var problems: [String] = []
        var details: [String] = []

        func intValue(_ key: String) -> Int? {
            if let value = object[key] as? Int { return value }
            if let value = object[key] as? NSNumber { return value.intValue }
            if let value = object[key] as? String { return Int(value) }
            return nil
        }

        if let format = object["format"] as? String {
            details.append("format: \(format)")
            if format != supportedFormat {
                problems.append("格式类型不匹配：\(format)（支持 \(supportedFormat)）")
            }
        } else {
            problems.append("缺少 format 字段")
        }

        func checkInt(_ key: String, expected: Int, label: String) {
            guard let value = intValue(key) else {
                problems.append("缺少 \(key) 字段")
                return
            }
            details.append("\(key): \(value)")
            if value != expected {
                problems.append("\(label)不匹配：\(value)（支持 \(expected)）")
            }
        }

        checkInt("format_version", expected: supportedFormatVersion, label: "格式版本")
        checkInt("embedding_version", expected: supportedEmbeddingVersion, label: "嵌入版本")
        checkInt("feature_version", expected: supportedFeatureVersion, label: "特征版本")
        checkInt("cls_rows", expected: supportedCLSRows, label: "CLS 行数")
        checkInt("tile_rows", expected: supportedTileRows, label: "tile 行数")
        checkInt("dim", expected: supportedDim, label: "特征维度")
        checkInt("base_dim", expected: supportedBaseDim, label: "base 维度")

        if problems.isEmpty {
            return Result(ok: true, message: "图库包版本正常", details: details)
        }
        return Result(
            ok: false,
            message: "图库包版本不兼容，请用最新导出器重新生成图库包\n" + problems.joined(separator: "\n"),
            details: details
        )
    }
}
