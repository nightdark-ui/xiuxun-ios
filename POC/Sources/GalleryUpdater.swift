import Foundation

/// 图库增量更新。
///
/// 前提（PC 导出的图库包满足）：
///   新款的记录**追加在 recall.bin / heavy.bin 末尾**，旧款顺序不变。
/// 满足时只需下载新增款的切片（每款约 1.2MB），否则退回整包重下。
///
/// 删除的款：只从索引里剔除（图片留在手机上，暂不回收空间）。
struct UpdatePlan {
    var serverCount: Int = 0
    var localCount: Int = 0
    var addedDesigns: [ServerDesign] = []
    var changedCount: Int = 0
    var removedCount: Int = 0
    var canAppend: Bool = false
    var serverIndexData: Data?

    var hasChanges: Bool { !addedDesigns.isEmpty || changedCount > 0 || removedCount > 0 }

    var estimateBytes: Int64 {
        Int64(addedDesigns.count) * 1_200_000
    }

    var summary: String {
        if !hasChanges { return "已是最新（\(localCount) 款）" }
        var parts: [String] = []
        if !addedDesigns.isEmpty { parts.append("新增 \(addedDesigns.count) 款") }
        if changedCount > 0 { parts.append("信息变更 \(changedCount) 款") }
        if removedCount > 0 { parts.append("移除 \(removedCount) 款") }
        let size = ByteCountFormatter.string(fromByteCount: estimateBytes, countStyle: .file)
        return parts.joined(separator: "，") + "（约需下载 \(size)）"
    }
}

struct ServerDesign {
    let uuid: String
    let code: String
    let title: String
    let library: String
    let image: String
    let heavyOffset: Int64
}

enum UpdateError: LocalizedError {
    case notInstalled
    case badIndex
    case needFullReload(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "还没有导入图库"
        case .badIndex: return "服务端的 index.json 无法解析"
        case .needFullReload(let reason): return "需要整包重下：\(reason)"
        }
    }
}

final class GalleryUpdater {
    private let installer = GalleryInstaller()
    private let fileManager = FileManager.default

    var galleryURL: URL { installer.galleryURL }

    private func fileSize(_ url: URL) -> Int64 {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let number = attributes[.size] as? NSNumber {
            return number.int64Value
        }
        return 0
    }

    // MARK: - 检查

    func check(serverBase: String) throws -> UpdatePlan {
        guard installer.hasGallery else { throw UpdateError.notInstalled }
        let local = try GalleryPackage(root: installer.galleryURL)

        guard let base = URL(string: serverBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.badIndex
        }
        let indexData = try Http.get(base.appendingPathComponent("files").appendingPathComponent("index.json"))
        guard let json = try JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let rawDesigns = json["designs"] as? [[String: Any]] else {
            throw UpdateError.badIndex
        }

        var serverDesigns: [ServerDesign] = []
        serverDesigns.reserveCapacity(rawDesigns.count)
        for item in rawDesigns {
            serverDesigns.append(
                ServerDesign(
                    uuid: item["feature_uuid"] as? String ?? "",
                    code: item["code"] as? String ?? "",
                    title: item["title"] as? String ?? "",
                    library: item["library"] as? String ?? "",
                    image: item["image"] as? String ?? "",
                    heavyOffset: (item["heavy_offset"] as? NSNumber)?.int64Value ?? 0
                )
            )
        }

        var plan = UpdatePlan()
        plan.serverCount = serverDesigns.count
        plan.localCount = local.count
        plan.serverIndexData = indexData

        let localDesigns = local.designs
        let serverByUUID = Dictionary(uniqueKeysWithValues: serverDesigns.map { ($0.uuid, $0) })
        let localUUIDs = Set(localDesigns.map { $0.featureUUID })
        let serverUUIDs = Set(serverDesigns.map { $0.uuid })

        // 新增：服务端有、本地没有
        plan.addedDesigns = serverDesigns.filter { !localUUIDs.contains($0.uuid) }
        // 移除：本地有、服务端没有
        plan.removedCount = localDesigns.filter { !serverUUIDs.contains($0.featureUUID) }.count
        // 变更：两边都有但字段不同
        plan.changedCount = localDesigns.filter { design in
            guard let server = serverByUUID[design.featureUUID] else { return false }
            return server.code != design.code
                || server.title != design.title
                || server.library != design.library
        }.count

        // 能否追加：本地款在服务端里顺序完全一致，且新增的都在末尾
        var canAppend = serverDesigns.count >= localDesigns.count
        if canAppend {
            for (index, design) in localDesigns.enumerated() {
                if serverDesigns[index].uuid != design.featureUUID {
                    canAppend = false
                    break
                }
            }
        }
        if canAppend {
            // recall.bin 大小必须等于 款数 × 记录大小
            let recallURL = installer.galleryURL.appendingPathComponent("recall.bin")
            let recallSize = fileSize(recallURL)
            if recallSize != Int64(localDesigns.count * GalleryPackage.recallBytes) {
                canAppend = false
            }
            // heavy.bin 末尾必须正好等于第一个新增款的偏移
            let heavyURL = installer.galleryURL.appendingPathComponent("heavy.bin")
            let heavySize = fileSize(heavyURL)
            if localDesigns.count < serverDesigns.count,
               serverDesigns[localDesigns.count].heavyOffset != heavySize {
                canAppend = false
            }
        }
        plan.canAppend = canAppend
        return plan
    }

    // MARK: - 应用更新

    func apply(
        plan: UpdatePlan,
        serverBase: String,
        progress: @escaping (InstallProgress) -> Void
    ) throws {
        guard installer.hasGallery else { throw UpdateError.notInstalled }
        guard let base = URL(string: serverBase.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw UpdateError.badIndex
        }
        guard plan.canAppend, let indexData = plan.serverIndexData else {
            throw UpdateError.needFullReload("款顺序有变化")
        }

        var state = InstallProgress(phase: "准备更新…")
        state.filesTotal = plan.addedDesigns.count * 4
        state.bytesTotal = plan.estimateBytes
        progress(state)

        let local = try GalleryPackage(root: installer.galleryURL)
        let localCount = local.count
        let recallURL = galleryURL.appendingPathComponent("recall.bin")
        let heavyURL = galleryURL.appendingPathComponent("heavy.bin")

        // 1) 追加 recall 记录
        let recallHandle = try FileHandle(forWritingTo: recallURL)
        defer { try? recallHandle.close() }
        try recallHandle.seekToEnd()
        for design in plan.addedDesigns {
            guard let serverIndex = plan.serverIndexData,
                  let offset = Self.recallOffset(uuid: design.uuid, indexData: serverIndex) else {
                throw UpdateError.badIndex
            }
            let record = try Http.get(
                base.appendingPathComponent("files").appendingPathComponent("recall.bin"),
                range: offset..<(offset + Int64(GalleryPackage.recallBytes))
            )
            try recallHandle.write(contentsOf: record)
            state.filesDone += 1
            state.bytesDone += Int64(record.count)
            progress(state)
        }

        // 2) 追加 heavy 记录（到下一个款的开头，最后一款到文件末尾）
        let heavySize = fileSize(heavyURL)
        let heavyHandle = try FileHandle(forWritingTo: heavyURL)
        defer { try? heavyHandle.close() }
        try heavyHandle.seekToEnd()
        for (index, design) in plan.addedDesigns.enumerated() {
            let start = design.heavyOffset
            let end: Int64
            if index + 1 < plan.addedDesigns.count {
                end = plan.addedDesigns[index + 1].heavyOffset
            } else {
                end = heavySize
            }
            guard end > start else { continue }
            let record = try Http.get(
                base.appendingPathComponent("files").appendingPathComponent("heavy.bin"),
                range: start..<end
            )
            try heavyHandle.write(contentsOf: record)
            state.filesDone += 1
            state.bytesDone += Int64(record.count)
            progress(state)
        }

        // 3) 下载新增图片与缩略图
        for design in plan.addedDesigns {
            for folder in ["images", "thumbs"] {
                let url = base.appendingPathComponent("files")
                    .appendingPathComponent(folder)
                    .appendingPathComponent(design.image)
                let data = try Http.get(url)
                let target = galleryURL
                    .appendingPathComponent(folder)
                    .appendingPathComponent(design.image)
                try data.write(to: target, options: .atomic)
            }
            state.filesDone += 2
            progress(state)
        }

        // 4) 备份旧 index.json，再用服务端版本覆盖
        let indexURL = galleryURL.appendingPathComponent("index.json")
        let backupURL = galleryURL.appendingPathComponent("index.json.prev")
        try? fileManager.removeItem(at: backupURL)
        if let oldIndex = try? Data(contentsOf: indexURL) {
            try? oldIndex.write(to: backupURL, options: .atomic)
        }
        try indexData.write(to: indexURL, options: .atomic)

        // 5) 校验：款数、recall 大小、heavy 末尾是否吻合
        let verifyPackage = try GalleryPackage(root: galleryURL)
        let recallSize = fileSize(recallURL)
        let expectedRecall = Int64(verifyPackage.count * GalleryPackage.recallBytes)
        let heavyEnd = fileSize(heavyURL)
        var heavyOK = true
        if let lastDesign = verifyPackage.designs.last {
            heavyOK = heavyEnd >= lastDesign.heavyOffset
        }
        if recallSize != expectedRecall || !heavyOK {
            // 回滚 index.json，避免出现"索引与二进制不一致"的坏状态
            if let backup = try? Data(contentsOf: backupURL) {
                try? backup.write(to: indexURL, options: .atomic)
            }
            throw UpdateError.needFullReload(
                "校验失败（recall \(recallSize)/\(expectedRecall)，heavy \(heavyEnd)），已回滚索引"
            )
        }
        try? fileManager.removeItem(at: backupURL)

        state.phase = "完成"
        state.filesDone = state.filesTotal
        progress(state)
        _ = localCount
    }

    /// 在 index.json 里找某款的序号 → recall.bin 偏移
    private static func recallOffset(uuid: String, indexData: Data) -> Int64? {
        guard let json = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
              let designs = json["designs"] as? [[String: Any]] else { return nil }
        for (index, item) in designs.enumerated()
        where (item["feature_uuid"] as? String) == uuid {
            return Int64(index * GalleryPackage.recallBytes)
        }
        return nil
    }
}

/// 极简 HTTP 客户端（同步）
enum Http {
    static func get(_ url: URL, range: Range<Int64>? = nil) throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if let range = range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        }
        var output: Result<Data, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                output = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                output = .failure(InstallError.http(-1))
                return
            }
            guard http.statusCode == 200 || http.statusCode == 206 else {
                output = .failure(InstallError.http(http.statusCode))
                return
            }
            output = .success(data ?? Data())
        }.resume()
        semaphore.wait()
        switch output {
        case .success(let data): return data
        case .failure(let error): throw error
        case .none: throw InstallError.http(-1)
        }
    }
}
