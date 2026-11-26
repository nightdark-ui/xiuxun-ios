import Foundation
import Accelerate

/// 「同花对齐」投影头：把冻结 DINOv2 的 CLS 特征映射到同花更近的空间。
/// 权重来自 227 对人工对照关系的对比学习（见 09-训练管线/train_pairs.py）。
/// 关闭开关时完全退化为原行为。
final class PairHead {
    static let shared = PairHead()
    static let dim = 384
    static let defaultsKey = "pairHeadEnabled.v1"

    private var weights: [Float] = []   // [out][in] 行主序 384x384
    private var bias: [Float] = []      // 384
    private var baseCache: [String: [Float]] = [:]

    var available: Bool { weights.count == Self.dim * Self.dim }

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.defaultsKey) }
    }

    var active: Bool { enabled && available }

    private init() {
        load()
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "pair_head", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return }
        let floats: [Float] = data.withUnsafeBytes { raw in
            let bound = raw.bindMemory(to: Float32.self)
            return Array(bound)
        }
        let need = Self.dim * Self.dim + Self.dim
        guard floats.count >= need else { return }
        weights = Array(floats[0..<(Self.dim * Self.dim)])
        bias = Array(floats[(Self.dim * Self.dim)..<need])
    }

    /// 单行变换：out = normalize(W·x + b)
    private func apply(row: UnsafePointer<Float>, out: inout [Float]) {
        out.withUnsafeMutableBufferPointer { dst in
            weights.withUnsafeBufferPointer { w in
                bias.withUnsafeBufferPointer { b in
                    for j in 0..<Self.dim {
                        var dot: Float = 0
                        vDSP_dotpr(row, 1, w.baseAddress!.advanced(by: j * Self.dim), 1, &dot, vDSP_Length(Self.dim))
                        dst[j] = dot + b[j]
                    }
                }
            }
            var norm: Float = 0
            vDSP_svesq(dst.baseAddress!, 1, &norm, vDSP_Length(Self.dim))
            var scale = Float(1.0 / max(1e-9, Double(norm).squareRoot()))
            vDSP_vsmul(dst.baseAddress!, 1, &scale, dst.baseAddress!, 1, vDSP_Length(Self.dim))
        }
    }

    /// 变换多行（每行 384 维，扁平数组）
    func transformFlat(_ rows: [Float]) -> [Float] {
        guard active, !rows.isEmpty, rows.count % Self.dim == 0 else { return rows }
        let n = rows.count / Self.dim
        var out = [Float](repeating: 0, count: rows.count)
        var tmp = [Float](repeating: 0, count: Self.dim)
        rows.withUnsafeBufferPointer { src in
            for r in 0..<n {
                apply(row: src.baseAddress!.advanced(by: r * Self.dim), out: &tmp)
                for i in 0..<Self.dim { out[r * Self.dim + i] = tmp[i] }
            }
        }
        return out
    }

    func transformRows(_ rows: [[Float]]) -> [[Float]] {
        guard active, !rows.isEmpty else { return rows }
        return rows.map { row in transformFlat(row) }
    }

    /// 图库侧 CLS 行（每款 5 行）整体变换，按图库路径缓存
    func transformedBase(package: GalleryPackage) -> [Float]? {
        guard active else { return nil }
        let key = package.root.path
        if let cached = baseCache[key] { return cached }
        let rows = GalleryPackage.clsRows
        var out = [Float](repeating: 0, count: package.count * rows * Self.dim)
        var tmp = [Float](repeating: 0, count: Self.dim)
        package.withRecallPointer { base, count in
            for index in 0..<count {
                let record = base.advanced(by: index * GalleryPackage.recallFloats)
                for r in 0..<rows {
                    apply(row: record.advanced(by: r * Self.dim), out: &tmp)
                    let dst = index * rows * Self.dim + r * Self.dim
                    for i in 0..<Self.dim { out[dst + i] = tmp[i] }
                }
            }
        }
        baseCache[key] = out
        return out
    }
}
