import Foundation

/// 图库安装进度
struct InstallProgress {
    var phase: String = ""
    var filesDone: Int = 0
    var filesTotal: Int = 0
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0

    var fraction: Double {
        bytesTotal > 0 ? min(1.0, Double(bytesDone) / Double(bytesTotal)) : 0
    }

    var text: String {
        let done = ByteCountFormatter.string(fromByteCount: bytesDone, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: bytesTotal, countStyle: .file)
        return "\(done) / \(total)　文件 \(filesDone)/\(filesTotal)"
    }
}

/// 从局域网服务（serve_gallery.py）把图库包下载到 App 沙盒。
///
/// 关键设计：
/// - 先下 `manifest.json`（路径 + 大小），据此算总进度
/// - 文件逐个校验大小，已存在且大小一致就跳过（**断点续传**）
/// - 全部下到 `Gallery.staging`，完成后**原子替换**成 `Gallery`，中途失败不影响旧图库
/// - 完成后再校验款数与 recall.bin 大小
final class GalleryInstaller {
    private let fileManager = FileManager.default
    private let root: URL
    private let staging: URL
    private let live: URL

    init() {
        // 放在 Documents 下：文件 App → 我的 iPhone → PicSeek → Gallery 可见，
        // 可以手动拷进来，其他 App 也能选这个文件夹读取。
        let documents = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        root = documents
        staging = root.appendingPathComponent("Gallery.staging", isDirectory: true)
        live = root.appendingPathComponent("Gallery", isDirectory: true)
        try? fileManager.createDirectory(at: live, withIntermediateDirectories: true)

        // 从旧位置（Application Support/Xiuxun/Gallery）迁移，避免重新导入
        if !FileManager.default.fileExists(atPath: live.appendingPathComponent("index.json").path),
           let support = try? FileManager.default.url(
               for: .applicationSupportDirectory, in: .userDomainMask,
               appropriateFor: nil, create: false
           ) {
            let legacy = support
                .appendingPathComponent("Xiuxun", isDirectory: true)
                .appendingPathComponent("Gallery", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.appendingPathComponent("index.json").path) {
                try? FileManager.default.removeItem(at: live)
                try? FileManager.default.moveItem(at: legacy, to: live)
            }
        }
    }

    var galleryURL: URL { live }

    var hasGallery: Bool {
        fileManager.fileExists(atPath: live.appendingPathComponent("index.json").path)
    }

    // MARK: - 安装

    func install(
        baseURL: String,
        progress: @escaping (InstallProgress) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws {
        guard let base = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw InstallError.badURL
        }
        try? fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var state = InstallProgress(phase: "获取清单…")
        progress(state)

        let manifest = try fetchManifest(base: base)
        state.filesTotal = manifest.files.count
        state.bytesTotal = manifest.totalSize
        state.phase = "下载中…"

        // 已存在的文件大小一致就跳过（断点续传）
        for file in manifest.files {
            let target = staging.appendingPathComponent(file.path)
            try? fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let attributes = try? fileManager.attributesOfItem(atPath: target.path),
               let size = attributes[.size] as? Int64, size == file.size {
                state.filesDone += 1
                state.bytesDone += file.size
                progress(state)
                continue
            }
            if isCancelled() { throw InstallError.cancelled }

            let remote = base.appendingPathComponent("files").appendingPathComponent(file.path)
            // 关键：大文件（heavy.bin 2.2GB）必须流式落盘，不能读进内存
            try downloadFile(remote, to: target)
            let written = (try? fileManager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard written == file.size else {
                try? fileManager.removeItem(at: target)
                throw InstallError.sizeMismatch(file.path)
            }

            state.filesDone += 1
            state.bytesDone += file.size
            progress(state)
        }

        // 校验
        state.phase = "校验中…"
        progress(state)
        // GalleryPackage 初始化时会校验 index.json 与 recall.bin 大小是否匹配
        let package = try GalleryPackage(root: staging)
        guard package.count > 0 else {
            throw InstallError.verify("款数为 0")
        }

        // 原子替换
        state.phase = "安装中…"
        progress(state)
        if fileManager.fileExists(atPath: live.path) {
            let backup = root.appendingPathComponent("Gallery.old", isDirectory: true)
            try? fileManager.removeItem(at: backup)
            try fileManager.moveItem(at: live, to: backup)
            do {
                try fileManager.moveItem(at: staging, to: live)
                try? fileManager.removeItem(at: backup)
            } catch {
                try? fileManager.moveItem(at: backup, to: live)
                throw error
            }
        } else {
            try fileManager.moveItem(at: staging, to: live)
        }

        state.phase = "完成"
        progress(state)
    }

    func removeGallery() throws {
        try? fileManager.removeItem(at: staging)
        if fileManager.fileExists(atPath: live.path) {
            try fileManager.removeItem(at: live)
        }
    }

    // MARK: - 网络

    private struct ManifestFile {
        let path: String
        let size: Int64
    }

    private struct Manifest {
        let files: [ManifestFile]
        let totalSize: Int64
    }

    private func fetchManifest(base: URL) throws -> Manifest {
        let url = base.appendingPathComponent("manifest.json")
        let data = try download(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["files"] as? [[String: Any]] else {
            throw InstallError.badManifest
        }
        var files: [ManifestFile] = []
        var total: Int64 = 0
        for item in items {
            guard let path = item["path"] as? String,
                  let size = (item["size"] as? NSNumber)?.int64Value else { continue }
            files.append(ManifestFile(path: path, size: size))
            total += size
        }
        guard !files.isEmpty else { throw InstallError.badManifest }
        return Manifest(files: files, totalSize: total)
    }

    /// 流式下载到指定文件（内存占用恒定，适合 GB 级文件）
    private func downloadFile(_ url: URL, to destination: URL) throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        var outcome: Result<URL, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: request) { location, response, error in
            defer { semaphore.signal() }
            if let error = error {
                outcome = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let location = location else {
                outcome = .failure(InstallError.http((response as? HTTPURLResponse)?.statusCode ?? -1))
                return
            }
            outcome = .success(location)
        }
        task.resume()
        semaphore.wait()

        switch outcome {
        case .success(let temporary):
            try? fileManager.removeItem(at: destination)
            try fileManager.moveItem(at: temporary, to: destination)
        case .failure(let error):
            throw error
        case .none:
            throw InstallError.http(-1)
        }
    }

    private func download(_ url: URL) throws -> Data {
        var result: Result<Data, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                result = .failure(InstallError.http((response as? HTTPURLResponse)?.statusCode ?? -1))
                return
            }
            result = .success(data ?? Data())
        }
        task.resume()
        semaphore.wait()
        switch result {
        case .success(let data): return data
        case .failure(let error): throw error
        case .none: throw InstallError.http(-1)
        }
    }
}

enum InstallError: LocalizedError {
    case badURL
    case badManifest
    case http(Int)
    case sizeMismatch(String)
    case verify(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badURL: return "地址格式不对，应该像 http://192.168.1.5:8765"
        case .badManifest: return "拿不到 manifest.json，检查电脑上的服务是否在运行"
        case .http(let code): return "下载失败（HTTP \(code)）"
        case .sizeMismatch(let path): return "文件大小不一致：\(path)"
        case .verify(let reason): return "图库校验失败：\(reason)"
        case .cancelled: return "已取消"
        }
    }
}
