import UIKit
import Foundation

/// 一条搜索结果
struct SearchHit {
    let design: DesignRef
    let score: Double
    let clsScore: Double
    let tileScore: Double
    let baseScore: Double
    var visionScore: Double = 0
    var structureScore: Double = 0
}

/// 分阶段耗时
struct SearchTimings {
    var preprocessMs: Double = 0
    var encodeMs: Double = 0
    var recallMs: Double = 0
    var baseMs: Double = 0
    var totalMs: Double = 0
    var compared: Int = 0

    var text: String {
        String(
            format: "预处理 %.0fms · 查询编码 %.0fms · 召回 %.0fms（%d 款）· base 重排 %.0fms · 合计 %.1fs",
            preprocessMs, encodeMs, recallMs, compared, baseMs, totalMs / 1000
        )
    }
}

struct SearchOutcome {
    var hits: [SearchHit]
    var timings: SearchTimings
    var note: String
}

/// 图库搜索（第一版：CLS + tile 召回，可选 base 重排；SIFT/结构校验后续再加）
final class GallerySearch {
    private let package: GalleryPackage
    private static let dim = 384
    private static let baseDim = 768

    private static let clsWeight = 0.65
    private static let tileWeight = 0.35

    init(package: GalleryPackage) {
        self.package = package
    }

    func search(
        enhancedGray: PilImaging.GrayImage,
        options: SearchOptions,
        encoder: QueryEncoder,
        progress: (String) -> Void = { _ in },
        shouldCancel: () -> Bool = { false },
        queryImage: UIImage? = nil,
        candidateImage: (DesignRef) -> UIImage? = { _ in nil }
    ) throws -> SearchOutcome {
        let started = Date()
        var timings = SearchTimings()

        // ---------- 1. 查询编码 ----------
        progress("编码查询特征…")
        let encodeStart = Date()
        let originalData = Data(
            (0..<(enhancedGray.width * enhancedGray.height)).map { enhancedGray.pixels[$0] }
        )
        let query = try encoder.encode(
            enhancedGray: enhancedGray,
            options: options,
            originalData: originalData
        )
        timings.encodeMs = Date().timeIntervalSince(encodeStart) * 1000

        // ---------- 2. 召回 ----------
        progress("扫描图库…")
        let recallStart = Date()
        let allowedLibraries = options.selectedLibraries
        let useLibraryFilter = !allowedLibraries.isEmpty

        var candidates: [(index: Int, cls: Double, tile: Double)] = []
        candidates.reserveCapacity(package.count)

        let fromNumber = Self.codeNumber(options.codeFrom)
        let toNumber = Self.codeNumber(options.codeTo)
        let useCodeRange = fromNumber != nil || toNumber != nil

        package.withRecallPointer { base, count in
            for index in 0..<count {
                if shouldCancel() { return }
                let design = package.designs[index]
                if useLibraryFilter && !allowedLibraries.contains(design.library) { continue }
                if useCodeRange {
                    guard let number = Self.codeNumber(design.code) else { continue }
                    if let low = fromNumber, number < low { continue }
                    if let high = toNumber, number > high { continue }
                }
                let record = base.advanced(by: index * GalleryPackage.recallFloats)
                let clsScore = Self.bestCosine(
                    queryRows: query.clsRows,
                    target: record,
                    rows: GalleryPackage.clsRows
                )
                let tileScore = query.tileRows.isEmpty ? 0 : Self.bestCosine(
                    queryRows: query.tileRows,
                    target: record.advanced(by: GalleryPackage.clsRows * Self.dim),
                    rows: GalleryPackage.tileRows
                )
                candidates.append((index, clsScore, tileScore))
                timings.compared = candidates.count
            }
        }

        // SL 系列门控：如果第一名明显属于 SL 库，则只在 SL 库内重新排序
        if shouldCancel() { throw InstallError.cancelled }

        var note = ""
        if candidates.isEmpty {
            timings.recallMs = Date().timeIntervalSince(recallStart) * 1000
            timings.totalMs = Date().timeIntervalSince(started) * 1000
            return SearchOutcome(hits: [], timings: timings, note: "没有可搜索的款（检查图库筛选）")
        }

        var ranked = candidates.sorted { Self.combined($0.cls, $0.tile) > Self.combined($1.cls, $1.tile) }
        if let top = ranked.first {
            let topDesign = package.designs[top.index]
            let topScore = Self.combined(top.cls, top.tile)
            let secondScore = ranked.count > 1 ? Self.combined(ranked[1].cls, ranked[1].tile) : 0
            let slCount = ranked.prefix(10).filter {
                package.designs[$0.index].library.contains("SL")
            }.count
            if topDesign.library.contains("SL"), topScore >= 0.85,
               topScore - secondScore >= 0.02, slCount >= 3 {
                ranked = ranked.filter { package.designs[$0.index].library.contains("SL") }
                note = "已启用 SL 系列门控"
            }
        }
        timings.recallMs = Date().timeIntervalSince(recallStart) * 1000

        if shouldCancel() { throw InstallError.cancelled }

        // ---------- 3. base 重排 ----------
        let baseLimit = options.deepReview ? 60 : 30
        let baseSize = options.deepReview ? 336 : options.baseInputSize
        var baseScores: [Int: Double] = [:]
        if ranked.count > 1 {
            progress("base 重排…")
            let baseStart = Date()
            if let baseQuery = try? encoder.encodeBase(enhancedGray: enhancedGray, size: baseSize) {
                let topForBase = Array(ranked.prefix(baseLimit))
                package.withRecallPointer { base, _ in
                    for item in topForBase {
                        let record = base.advanced(by: item.index * GalleryPackage.recallFloats)
                        let target = record.advanced(by: (GalleryPackage.clsRows + GalleryPackage.tileRows) * Self.dim)
                        baseScores[item.index] = Self.cosine(baseQuery, target, Self.baseDim)
                    }
                }
            }
            timings.baseMs = Date().timeIntervalSince(baseStart) * 1000
        }

        // ---------- 4. 组装结果 ----------
        let finalHits: [SearchHit] = ranked.prefix(max(1, options.resultCount)).map { item in
            let ai = Self.combined(item.cls, item.tile)
            let baseScore = baseScores[item.index] ?? 0
            let score = baseScores[item.index] == nil ? ai : ai * 0.7 + baseScore * 0.3
            return SearchHit(
                design: package.designs[item.index],
                score: score,
                clsScore: item.cls,
                tileScore: item.tile,
                baseScore: baseScore
            )
        }

        // ---------- 5. 深度复核：Vision + 结构 三路融合 ----------
        var finalList = finalHits
        if options.deepReview, let query = queryImage, finalList.count > 1 {
            progress("深度复核…")
            let visionQuery = ExtraScores.visionPrint(query)
            let structureQuery = ExtraScores.structureSignature(query)
            var enriched: [SearchHit] = []
            enriched.reserveCapacity(finalList.count)
            for var hit in finalList {
                var vision = 0.0
                var structure = 0.0
                if let candidate = candidateImage(hit.design) {
                    if let a = visionQuery, let b = ExtraScores.visionPrint(candidate) {
                        vision = max(0, ExtraScores.cosine(a, b))
                    }
                    if let a = structureQuery, let b = ExtraScores.structureSignature(candidate) {
                        structure = max(0, ExtraScores.cosine(a, b))
                    }
                }
                hit.visionScore = vision
                hit.structureScore = structure
                if vision > 0 || structure > 0 {
                    // 0.6 DINO + 0.25 Vision + 0.15 结构
                    hit.score = 0.6 * hit.score + 0.25 * vision + 0.15 * structure
                }
                enriched.append(hit)
            }
            finalList = enriched.sorted { $0.score > $1.score }
            note += note.isEmpty ? "已启用深度复核" : "；已启用深度复核"
        }

        timings.totalMs = Date().timeIntervalSince(started) * 1000
        if query.fromCache { note += note.isEmpty ? "查询特征命中缓存" : "；查询特征命中缓存" }
        return SearchOutcome(hits: finalList, timings: timings, note: note)
    }

    /// 从编号里取出数字部分（SL9015 → 9015）
    static func codeNumber(_ code: String) -> Int? {
        let digits = code.compactMap { $0.isNumber ? $0 : nil }
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    // MARK: - 数学

    private static func combined(_ cls: Double, _ tile: Double) -> Double {
        tile <= 0 ? cls : cls * clsWeight + tile * tileWeight
    }

    private static func bestCosine(
        queryRows: [[Float]],
        target: UnsafePointer<Float>,
        rows: Int
    ) -> Double {
        var best = -1.0
        for row in queryRows {
            for r in 0..<rows {
                let pointer = target.advanced(by: r * dim)
                var dot = 0.0
                var normQ = 0.0
                var normT = 0.0
                for i in 0..<dim {
                    let q = Double(row[i])
                    let t = Double(pointer[i])
                    dot += q * t
                    normQ += q * q
                    normT += t * t
                }
                let cosine = dot / max(1e-9, sqrt(normQ) * sqrt(normT))
                if cosine > best { best = cosine }
            }
        }
        return max(0, best)
    }

    private static func cosine(_ a: [Float], _ b: UnsafePointer<Float>, _ count: Int) -> Double {
        var dot = 0.0
        var normA = 0.0
        var normB = 0.0
        for i in 0..<count {
            let x = Double(a[i])
            let y = Double(b[i])
            dot += x * y
            normA += x * x
            normB += y * y
        }
        return dot / max(1e-9, sqrt(normA) * sqrt(normB))
    }
}
