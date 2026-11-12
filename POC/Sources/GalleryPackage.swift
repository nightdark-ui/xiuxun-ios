import Foundation

/// 一款设计图的元数据（对应 index.json 的 designs[]）
struct DesignRef {
    let index: Int
    let id: Int
    let code: String
    let title: String
    let library: String
    let image: String
    let featureUUID: String
    let heavyOffset: Int64
    let siftCount: Int
}

/// 读取 PC/安卓 生成的图库包（xiuxun-android-index v1）。
///
/// 目录结构：
///   index.json      款元数据 + 特征偏移
///   recall.bin      每款 cls(5×384) + tiles(9×384) + base_cls(768)
///   heavy.bin       tiles5(25×384) + 全局描述子 + SIFT（按需读取）
///   images/         1400px ԭͼ
///   thumbs/         缩略图
///
/// recall.bin 用内存映射打开，避免一次读进内存（3.5GB 图库时很关键）。
final class GalleryPackage {
    static let clsRows = 5
    static let tileRows = 9
    static let dim = 384
    static let baseDim = 768
    static let recallFloats = clsRows * dim + tileRows * dim + baseDim
    static let recallBytes = recallFloats * 4

    let root: URL
    let designs: [DesignRef]
    let meta: [String: String]
    private let recall: Data

    var count: Int { designs.count }

    /// 款号 → 该款全部图片文件名（主图在前）。一款多图时用于详情页展示。
    private(set) lazy var imagesByCode: [String: [String]] = {
        var map: [String: [String]] = [:]
        for design in designs {
            map[design.code, default: []].append(design.image)
        }
        return map
    }()

    /// 该款全部图片的 URL（主图在前）
    func imageURLs(for design: DesignRef) -> [URL] {
        let names = imagesByCode[design.code] ?? [design.image]
        return names.map { root.appendingPathComponent(images).appendingPathComponent() }
    }

    init(root: URL) throws {
        self.root = root
        let indexURL = root.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            throw GalleryError.missingIndex
        }
        let indexData = try Data(contentsOf: indexURL)
        guard let json = try JSONSerialization.jsonObject(with: indexData) as? [String: Any] else {
            throw GalleryError.badIndex("index.json 不是对象")
        }
        guard let format = json["format"] as? String, format == "xiuxun-android-index" else {
            throw GalleryError.badIndex("format 不是 xiuxun-android-index")
        }

        var meta: [String: String] = [:]
        for (key, value) in json where key != "designs" {
            if let text = value as? String { meta[key] = text }
            else if let number = value as? NSNumber { meta[key] = number.stringValue }
        }
        self.meta = meta

        guard let rawDesigns = json["designs"] as? [[String: Any]] else {
            throw GalleryError.badIndex("designs 不是数组")
        }
        var designs: [DesignRef] = []
        designs.reserveCapacity(rawDesigns.count)
        for (position, item) in rawDesigns.enumerated() {
            designs.append(
                DesignRef(
                    index: position,
                    id: item["id"] as? Int ?? position,
                    code: item["code"] as? String ?? "",
                    title: item["title"] as? String ?? "",
                    library: item["library"] as? String ?? "",
                    image: item["image"] as? String ?? "",
                    featureUUID: item["feature_uuid"] as? String ?? "",
                    heavyOffset: (item["heavy_offset"] as? NSNumber)?.int64Value ?? 0,
                    siftCount: item["sift_count"] as? Int ?? 0
                )
            )
        }
        self.designs = designs

        let recallURL = root.appendingPathComponent("recall.bin")
        guard FileManager.default.fileExists(atPath: recallURL.path) else {
            throw GalleryError.missingFile("recall.bin")
        }
        let mapped = try Data(contentsOf: recallURL, options: .mappedIfSafe)
        let expected = designs.count * Self.recallBytes
        guard mapped.count >= expected else {
            throw GalleryError.badIndex(
                "recall.bin 大小 (mapped.count) 与款数 (designs.count) 不符（应为 (expected)）"
            )
        }
        self.recall = mapped
    }

    /// 遍历每款的 recall 记录（cls 5×384 + tiles 9×384 + base 768），零拷贝
    func withRecall<T>(index: Int, _ body: (UnsafePointer<Float>) throws -> T) rethrows -> T {
        let offset = index * Self.recallBytes
        return try recall.withUnsafeBytes { raw -> T in
            let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float.self)
            return try body(base)
        }
    }

    /// 一次性拿到整个 recall.bin 的指针，供搜索阶段遍历（零拷贝、最快）
    func withRecallPointer<T>(_ body: (UnsafePointer<Float>, Int) throws -> T) rethrows -> T {
        try recall.withUnsafeBytes { raw in
            let base = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            return try body(base, designs.count)
        }
    }

    func imageURL(for design: DesignRef) -> URL {
        root.appendingPathComponent("images").appendingPathComponent(design.image)
    }

    func thumbURL(for design: DesignRef) -> URL {
        root.appendingPathComponent("thumbs").appendingPathComponent(design.image)
    }

    /// 按库名统计（用于界面显示「各库多少款」）
    func libraryCounts() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for design in designs {
            counts[design.library, default: 0] += 1
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }
}

enum GalleryError: LocalizedError {
    case missingIndex
    case missingFile(String)
    case badIndex(String)

    var errorDescription: String? {
        switch self {
        case .missingIndex: return "这个文件夹里没有 index.json，选的不是图库包"
        case .missingFile(let name): return "图库包缺少 (name)"
        case .badIndex(let reason): return "index.json 有问题：(reason)"
        }
    }
}
