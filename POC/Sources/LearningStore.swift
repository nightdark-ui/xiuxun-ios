import Foundation

/// 参考学习样本（对应安卓学习包里的一个 `samples/<uuid>_<id>.npz`）
struct ReferenceSample: Codable {
    var featureUUID: String
    var sampleID: String
    /// cls 行 × 384（扁平存储，rows = count / 384）
    var cls: [Float]
    /// tile 行 × 384
    var tiles: [Float]

    var clsRows: Int { cls.count / 384 }
    var tileRows: Int { tiles.count / 384 }
}

/// 参考学习存储 + 学习包导入导出（安卓 `xiuxun-learning` v1）
final class LearningStore: ObservableObject {
    static let shared = LearningStore()

    @Published private(set) var samples: [ReferenceSample] = []
    private var byUUID: [String: [ReferenceSample]] = [:]
    private let queue = DispatchQueue(label: "xiuxun.learning")

    var directory: URL {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("Learning", isDirectory: true)
    }

    private var storeURL: URL { directory.appendingPathComponent("samples.json") }

    private init() {
        load()
    }

    // MARK: - 存取


    /// 内置学习包（构建时打进 IPA 的 learning.bin）
    private var bundled: [ReferenceSample] = []
    private var bundledLoaded = false
    private var bundledIndex: [String: [ReferenceSample]] = [:]

    /// 读取 Resources/learning.bin（格式 LRN1）
    func loadBundled() {
        guard !bundledLoaded else { return }
        bundledLoaded = true
        guard let url = Bundle.main.url(forResource: "learning", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return }

        var offset = 0
        func readInt() -> Int32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.load(fromByteOffset: offset, as: Int32.self) }
            offset += 4
            return value
        }
        guard data.count > 8,
              String(data: data.prefix(4), encoding: .ascii) == "LRN1" else { return }
        offset = 4
        guard let rawCount = readInt() else { return }
        let count = Int(rawCount)
        let floatCount = 10 * 384 + 9 * 384

        for index in 0..<count {
            guard let rawLen = readInt(), rawLen > 0, rawLen < 256,
                  offset + Int(rawLen) <= data.count else { break }
            let uuid = String(
                data: data.subdata(in: offset..<(offset + Int(rawLen))),
                encoding: .utf8
            ) ?? ""
            offset += Int(rawLen)
            let byteCount = floatCount * 4
            guard offset + byteCount <= data.count else { break }
            let floats = data.withUnsafeBytes { buffer -> [Float] in
                let pointer = buffer.baseAddress!.advanced(by: offset).assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: pointer, count: floatCount))
            }
            offset += byteCount
            let sample = ReferenceSample(
                featureUUID: uuid,
                sampleID: "bundled-\(index)",
                cls: Array(floats[0..<(10 * 384)]),
                tiles: Array(floats[(10 * 384)..<floatCount])
            )
            bundled.append(sample)
        }
        rebuildBundledIndex()
    }

    private func rebuildBundledIndex() {
        bundledIndex = [:]
        for sample in bundled {
            bundledIndex[sample.featureUUID, default: []].append(sample)
        }
    }

    var bundledCount: Int {
        if !bundledLoaded { loadBundled() }
        return bundled.count
    }

    /// 查询图与内置样本的最大余弦（按款 uuid 汇总）
    func bundledBoostMap(queryRows: [[Float]]) -> [String: Double] {
        if !bundledLoaded { loadBundled() }
        guard !bundled.isEmpty, !queryRows.isEmpty else { return [:] }
        var result: [String: Double] = [:]
        for sample in bundled {
            let rows = sample.clsRows
            guard rows > 0 else { continue }
            var best = 0.0
            for q in queryRows {
                for r in 0..<rows {
                    let offset = r * 384
                    var dot = 0.0
                    var nq = 0.0
                    var nt = 0.0
                    for i in 0..<384 {
                        let qv = Double(q[i])
                        let tv = Double(sample.cls[offset + i])
                        dot += qv * tv
                        nq += qv * qv
                        nt += tv * tv
                    }
                    let value = dot / max(1e-9, (nq * nt).squareRoot())
                    if value > best { best = value }
                    if best > 0.999 { break }
                }
            }
            if best > (result[sample.featureUUID] ?? 0) {
                result[sample.featureUUID] = best
            }
        }
        return result
    }

    func load() {
        queue.sync {
            guard let data = try? Data(contentsOf: storeURL),
                  let decoded = try? JSONDecoder().decode([ReferenceSample].self, from: data) else {
                samples = []
                byUUID = [:]
                return
            }
            samples = decoded
            rebuildIndex()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(samples) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    private func rebuildIndex() {
        byUUID = [:]
        // 导出 = 内置样本 + 本地样本（并集，按 uuid+sampleID 去重）
        if !bundledLoaded { loadBundled() }
        var exportAll: [ReferenceSample] = bundled
        var seen = Set<String>()
        for sample in exportAll { seen.insert(sample.featureUUID + "|" + sample.sampleID) }
        for sample in samples {
            let key = sample.featureUUID + "|" + sample.sampleID
            if seen.contains(key) { continue }
            seen.insert(key)
            exportAll.append(sample)
        }
        for sample in exportAll {
            byUUID[sample.featureUUID, default: []].append(sample)
        }
    }

    func samples(for uuid: String) -> [ReferenceSample] {
        byUUID[uuid] ?? []
    }

    var totalSamples: Int { samples.count }
    var uuidCount: Int { byUUID.count }

    func clear() {
        queue.sync {
            samples = []
            byUUID = [:]
            save()
        }
    }

    // MARK: - 打分

    /// 参考学习分：查询 CLS 与样本 CLS 的最大余弦（0…1）
    func referenceScore(queryRows: [[Float]], uuid: String) -> Double {
        let refs = samples(for: uuid)
        guard !refs.isEmpty else { return -1 }
        var best = -1.0
        for sample in refs where sample.clsRows > 0 {
            for rowIndex in 0..<sample.clsRows {
                let start = rowIndex * 384
                guard start + 384 <= sample.cls.count else { break }
                for query in queryRows {
                    let cosine = Self.cosine(query, sample.cls, start)
                    if cosine > best { best = cosine }
                }
            }
        }
        return best
    }

    private static func cosine(_ query: [Float], _ target: [Float], _ offset: Int) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        let count = min(384, query.count)
        for i in 0..<count {
            let x = Double(query[i])
            let y = Double(target[offset + i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    // MARK: - 导入

    struct ImportResult {
        var added = 0
        var skipped = 0
        var message = ""
    }

    /// 导入安卓学习包（zip）
    /// 参考分：内置包 + 本地样本取最大（人工确认后立即生效）
    func boostMap(queryRows: [[Float]]) -> [String: Double] {
        var result = bundledBoostMap(queryRows: queryRows)
        guard !queryRows.isEmpty else { return result }
        for sample in samples {
            let rows = sample.clsRows
            guard rows > 0 else { continue }
            var best = 0.0
            for query in queryRows {
                for row in 0..<rows {
                    let offset = row * 384
                    var dot = 0.0
                    var normQuery = 0.0
                    var normSample = 0.0
                    for index in 0..<384 {
                        let q = Double(query[index])
                        let s = Double(sample.cls[offset + index])
                        dot += q * s
                        normQuery += q * q
                        normSample += s * s
                    }
                    let value = dot / max(1e-9, (normQuery * normSample).squareRoot())
                    if value > best { best = value }
                }
            }
            if best > (result[sample.featureUUID] ?? 0) {
                result[sample.featureUUID] = best
            }
        }
        return result
    }

    /// 记录一次人工确认（款 uuid + 当前查询特征）
    private(set) var lastAddedSampleID: String?

    /// 撤回最近一次确认
    @discardableResult
    func removeSample(sampleID: String) -> Bool {
        guard let index = samples.firstIndex(where: { $0.sampleID == sampleID }) else { return false }
        samples.remove(at: index)
        rebuildIndex()
        save()
        if lastAddedSampleID == sampleID { lastAddedSampleID = nil }
        return true
    }

    func addSample(featureUUID: String, cls: [Float], tiles: [Float]) -> Bool {
        guard !featureUUID.isEmpty, !cls.isEmpty, cls.count % 384 == 0 else { return false }
        let sample = ReferenceSample(
            featureUUID: featureUUID,
            sampleID: "local-\(Int(Date().timeIntervalSince1970))",
            cls: cls,
            tiles: tiles
        )
        samples.append(sample)
        rebuildIndex()
        save()
        lastAddedSampleID = sample.sampleID
        return true
    }

    func importPack(from url: URL) throws -> ImportResult {
        let data = try Data(contentsOf: url)
        guard let reader = ZipReader(data) else {
            throw LearningError.badZip
        }

        var added = 0
        var skipped = 0
        var imported: [ReferenceSample] = []

        // 安卓学习包：samples/<sample_id>.npz，uuid 写在 manifest.json 里
        var manifestMap: [String: (uuid: String, sampleID: String)] = [:]
        if let manifestData = reader.payload(named: "manifest.json"),
           let object = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
           let list = object["samples"] as? [[String: Any]] {
            for item in list {
                let uuid = item["feature_uuid"] as? String ?? ""
                let sampleID = item["sample_id"] as? String ?? ""
                var stem = ""
                if let reference = item["reference_file"] as? String {
                    stem = (reference as NSString).lastPathComponent
                    stem = (stem as NSString).deletingPathExtension
                }
                if stem.isEmpty { stem = sampleID }
                if !uuid.isEmpty, !stem.isEmpty {
                    manifestMap[stem] = (uuid, sampleID.isEmpty ? stem : sampleID)
                }
            }
        }

        for item in reader.items where item.name.hasSuffix(".npz") {
            guard let npzData = reader.payload(named: item.name),
                  let npz = ZipReader(npzData) else {
                skipped += 1
                continue
            }
            let name = (item.name as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let parts = stem.split(separator: "_", maxSplits: 1)
            // 优先用 manifest 映射（安卓包文件名只有 sample_id）
            let mapped = manifestMap[stem]
            let uuid = mapped?.uuid ?? parts.first.map(String.init) ?? stem
            let sampleID = mapped?.sampleID ?? (parts.count > 1 ? String(parts[1]) : "0")

            var cls: [Float] = []
            var tiles: [Float] = []
            if let array = npz.payload(named: "cls.npy").flatMap(NpyArray.parse) {
                cls = array.values
            }
            if let array = npz.payload(named: "tiles.npy").flatMap(NpyArray.parse) {
                tiles = array.values
            }
            if cls.isEmpty && tiles.isEmpty {
                skipped += 1
                continue
            }
            imported.append(ReferenceSample(
                featureUUID: uuid,
                sampleID: sampleID,
                cls: cls,
                tiles: tiles
            ))
            added += 1
        }

        queue.sync {
            let existing = Set(samples.map { "\($0.featureUUID)#\($0.sampleID)" })
            for sample in imported where !existing.contains("\(sample.featureUUID)#\(sample.sampleID)") {
                samples.append(sample)
            }
            rebuildIndex()
            save()
        }

        var result = ImportResult()
        result.added = added
        result.skipped = skipped
        result.message = "已导入 \(added) 个样本，跳过 \(skipped) 个；当前共 \(totalSamples) 个样本、\(uuidCount) 款"
        return result
    }

    // MARK: - 导出

    /// 导出为安卓兼容的学习包（zip：manifest.json + samples/*.npz + checksums.json）
    func exportPack(to url: URL) throws -> Int {
        var writer = ZipWriter()
        var fileList: [String] = []

        let manifest: [String: Any] = [
            "format": "xiuxun-learning",
            "format_version": 1,
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "sample_count": samples.count + bundled.count,
            "design_count": uuidCount,
            "cls_rows": 10,
            "tile_rows": 9,
            "dim": 384,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        writer.add(name: "manifest.json", payload: manifestData)
        fileList.append("manifest.json")

        var checksums: [String: String] = [:]
        checksums["manifest.json"] = String(format: "%08x", CRC32.checksum(manifestData))

        for sample in samples {
            var npz = ZipWriter()
            npz.add(name: "cls.npy", payload: NpyWriter.float32(sample.cls, shape: [sample.clsRows, 384]))
            npz.add(name: "tiles.npy", payload: NpyWriter.float32(sample.tiles, shape: [sample.tileRows, 384]))
            let npzData = npz.finish()
            let name = "samples/\(sample.featureUUID)_\(sample.sampleID).npz"
            writer.add(name: name, payload: npzData)
            fileList.append(name)
            checksums[name] = String(format: "%08x", CRC32.checksum(npzData))
        }

        let checksumData = try JSONSerialization.data(withJSONObject: checksums, options: [.sortedKeys, .prettyPrinted])
        writer.add(name: "checksums.json", payload: checksumData)

        let readme = """
        xiuxun-learning v1
        样本数：\(samples.count)
        款数：\(uuidCount)
        每个样本：samples/<feature_uuid>_<sample_id>.npz（内含 cls.npy / tiles.npy，float32）
        """
        writer.add(name: "README.txt", payload: Data(readme.utf8))

        let archive = writer.finish()
        try archive.write(to: url, options: .atomic)
        return samples.count
    }
}

enum LearningError: LocalizedError {
    case badZip

    var errorDescription: String? {
        switch self {
        case .badZip: return "不是有效的 zip 文件"
        }
    }
}
