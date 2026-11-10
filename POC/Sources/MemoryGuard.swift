import Foundation
import UIKit
import SwiftUI

/// 内存防护：长时间多次搜索后内存不会越用越多。
///
/// 三条线：
///  1. 缩略图走 NSCache（上限 48MB，系统内存紧张时自动回收）
///  2. 查询特征缓存目录按"最多 20 份 / 200MB"裁剪，超出删最旧的
///  3. 收到内存警告时立刻清空上面两者，并释放大对象
final class MemoryGuard {
    static let shared = MemoryGuard()

    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "xiuxun.memoryguard")

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 48 * 1024 * 1024
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.trim(reason: "内存警告")
        }
    }

    func start() {
        // 启动时先裁一次，清掉上次残留的超额缓存
        trim(reason: "启动")
    }

    // MARK: - 缩略图

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url.path as NSString)
    }

    func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url.path as NSString, cost: estimatedCost(image))
    }

    // MARK: - 清理

    func trim(reason: String) {
        cache.removeAllObjects()
        queue.async { Self.pruneQueryCache() }
        NSLog("[MemoryGuard] trimmed (%@)", reason)
    }

    /// 查询缓存目录裁剪：最多 20 份，最多 200MB
    private static func pruneQueryCache() {
        let fileManager = FileManager.default
        guard let support = try? fileManager.url(
            for: .cachesDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ) else { return }
        let dir = support.appendingPathComponent("XiuxunQuery", isDirectory: true)
        guard let files = try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var entries: [(url: URL, date: Date, size: Int)] = []
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            entries.append((
                file,
                values?.contentModificationDate ?? .distantPast,
                values?.fileSize ?? 0
            ))
        }
        entries.sort { $0.date > $1.date }

        let maxCount = 20
        let maxBytes = 200 * 1024 * 1024
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.size
            if index >= maxCount || total > maxBytes {
                try? fileManager.removeItem(at: entry.url)
            }
        }
    }

    private func estimatedCost(_ image: UIImage) -> Int {
        Int(image.size.width * image.size.height * image.scale * image.scale * 4)
    }
}

/// 带缓存的缩略图加载（替代裸 AsyncImage，避免反复解码）
struct CachedThumb: View {
    let url: URL?
    var height: CGFloat = 120

    init(url: URL?, height: CGFloat = 120) {
        self.url = url
        self.height = height
    }

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            UI.pageBackground
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .task(id: url) {
            guard let url = url else { return }
            if let cached = MemoryGuard.shared.image(for: url) {
                image = cached
                return
            }
            let target = url
            let loaded: UIImage? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let data = try? Data(contentsOf: target)
                    let decoded = data.flatMap { UIImage(data: $0) }
                    continuation.resume(returning: decoded)
                }
            }
            if let loaded = loaded {
                MemoryGuard.shared.store(loaded, for: target)
                image = loaded
            }
        }
    }
}
