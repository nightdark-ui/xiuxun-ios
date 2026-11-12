import Foundation

/// 设计图 canonical 512 缓存：SIFT 和 dense 共用，避免重复解码/裁切。
/// key = 设计图路径；LRU 上限 80 条（约 80 × 0.8MB ≈ 64MB）。
final class DesignCanonicalCache {
    static let shared = DesignCanonicalCache()

    private var storage: [String: Data] = [:]
    private var order: [String] = []
    private let lock = NSLock()
    private let limit = 80

    func image(path: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = storage[path] else { return nil }
        if let index = order.firstIndex(of: path) {
            order.remove(at: index)
            order.append(path)
        }
        return data
    }

    func store(path: String, data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage[path] = data
        if let index = order.firstIndex(of: path) { order.remove(at: index) }
        order.append(path)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        order.removeAll()
    }
}
