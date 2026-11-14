import UIKit
import Foundation
import Accelerate

/// 一条搜索结果
struct SearchHit {
    let design: DesignRef
    var score: Double
    let clsScore: Double
    let tileScore: Double
    let baseScore: Double
    var visionScore: Double = 0
    var structureScore: Double = 0
    var aiScore: Double = 0
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
    private let heavy: HeavyStore?
    private static let dim = 384
    private static let baseDim = 768

    private static let clsWeight = 0.65
    private static let tileWeight = 0.35

    init(package: GalleryPackage) {
        self.package = package
        self.heavy = HeavyStore(root: package.root)
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
        // PC 的查询预处理（OpenCV 直译）：canonical 512 → 灰度 → CLAHE(2.0, 8×8)
        var canonicalBytes: Data?
        var canonicalWidth = 512
        var canonicalHeight = 512
        var workingGray = enhancedGray
        if let image = queryImage,
           let bytes = ImageOps.rgbaBytes(image, maxSide: 1280),
           let canonical = CVImaging.canonicalRGBA(
               bytes.data,
               width: bytes.width,
               height: bytes.height,
               autoCrop: options.autoCrop,
               outWidth: &canonicalWidth,
               outHeight: &canonicalHeight
           ),
           let gray = CVImaging.claheGray(
               fromRGBA: canonical,
               width: 512,
               height: 512
           ) {
            canonicalBytes = canonical
            let pixels = [UInt8](gray)
            workingGray = PilImaging.GrayImage(width: 512, height: 512, pixels: pixels)
        }

        var encodeOptions = options
        encodeOptions.autoCrop = false   // canonical 已经处理过裁切
        let query = try encoder.encode(
            enhancedGray: workingGray,
            options: encodeOptions,
            originalData: originalData
        )
        timings.encodeMs = Date().timeIntervalSince(encodeStart) * 1000

        // ---------- 2. 召回 ----------
        progress("扫描图库…")
        let recallStart = Date()
        let allowedLibraries = options.selectedLibraries
        let useLibraryFilter = !allowedLibraries.isEmpty

        // PC 的 base CLS 全库召回通道（768 维，判别力强于 small 的 384）
        let queryBaseVector: [Float]? = try? encoder.encodeBase(enhancedGray: workingGray, size: options.baseInputSize)

        var candidates: [(index: Int, cls: Double, tile: Double, fraction: Double)] = []
        var baseSims: [Int: Double] = [:]
        candidates.reserveCapacity(package.count)

        let fromNumber = Self.codeNumber(options.codeFrom)
        let toNumber = Self.codeNumber(options.codeTo)
        let useCodeRange = fromNumber != nil || toNumber != nil
        // 前缀：SL1001-SL2000 只在 SL 里找；TM001-TM299 只在 TM 里找
        let fromPrefix = Self.codePrefix(options.codeFrom)
        let toPrefix = Self.codePrefix(options.codeTo)
        let rangePrefix: String? = {
            if !fromPrefix.isEmpty && !toPrefix.isEmpty {
                return fromPrefix == toPrefix ? fromPrefix : nil
            }
            return fromPrefix.isEmpty ? (toPrefix.isEmpty ? nil : toPrefix) : fromPrefix
        }()

        package.withRecallPointer { base, count in
            for index in 0..<count {
                if shouldCancel() { return }
                let design = package.designs[index]
                if useLibraryFilter && !allowedLibraries.contains(design.library) { continue }
                if useCodeRange {
                    guard let number = Self.codeNumber(design.code) else { continue }
                    if let prefix = rangePrefix, Self.codePrefix(design.code) != prefix { continue }
                    if let low = fromNumber, number < low { continue }
                    if let high = toNumber, number > high { continue }
                }
                let record = base.advanced(by: index * GalleryPackage.recallFloats)
                let clsResult = Self.bestCosineWithRow(
                    queryRows: query.clsRows,
                    target: record,
                    rows: GalleryPackage.clsRows
                )
                let clsScore = clsResult.score
                // 设计侧 5 行对应 5 个尺度，记下命中的那个用于 dense
                let designFraction = DinoEncoder.designFractions[
                    min(clsResult.row, DinoEncoder.designFractions.count - 1)
                ]
                let tileScore = query.tileRows.isEmpty ? 0 : Self.bestCosine(
                    queryRows: query.tileRows,
                    target: record.advanced(by: GalleryPackage.clsRows * Self.dim),
                    rows: GalleryPackage.tileRows
                )
                var baseSim = 0.0
                if let baseQuery = queryBaseVector {
                    let basePtr = record.advanced(by: GalleryPackage.clsRows * GalleryPackage.dim
                        + GalleryPackage.tileRows * GalleryPackage.dim)
                    var dot = 0.0
                    var normB = 0.0
                    for i in 0..<GalleryPackage.baseDim {
                        let b = Double(basePtr[i])
                        dot += Double(baseQuery[i]) * b
                        normB += b * b
                    }
                    if normB > 1e-9 {
                        baseSim = dot / normB.squareRoot()
                    }
                }
                baseSims[index] = baseSim
                candidates.append((index, clsScore, tileScore, designFraction))
                timings.compared = candidates.count
            }
        }

        // SL 系列门控：如果第一名明显属于 SL 库，则只在 SL 库内重新排序
        if shouldCancel() { throw InstallError.cancelled }

        var note = ""
        if candidates.isEmpty {
            timings.recallMs = Date().timeIntervalSince(recallStart) * 1000
            // 诊断款号：输出召回名次与最终名次
        let diagnostic = options.diagnosticCode.trimmingCharacters(in: .whitespaces)
        if !diagnostic.isEmpty {
            if let design = package.designs.first(where: {
                $0.code.uppercased() == diagnostic.uppercased()
            }) {
                let recallRank = ranked.firstIndex(where: { $0.index == design.index }).map { $0 + 1 }
                let finalRank = finalList.firstIndex(where: { $0.design.index == design.index }).map { $0 + 1 }
                let recallText = recallRank.map { "第\($0)" } ?? "未入围"
                let finalText = finalRank.map { "第\($0)" } ?? "未入围"
                note += "；诊断 \(design.code)：召回\(recallText)，最终\(finalText)"
            } else {
                note += "；诊断 \(diagnostic)：图库里没有这个款号"
            }
        }

        timings.totalMs = Date().timeIntervalSince(started) * 1000
            return SearchOutcome(hits: [], timings: timings, note: "没有可搜索的款（检查图库筛选）")
        }

        // 第三召回通道：查询图 vs 全库 25 个细 tile（局部图靠它）
        var fineTiles: [Int: Double] = [:]
        if let heavy = heavy, !query.clsRows.isEmpty {
            progress("细粒度比对…")
            // 只用 8 个旋转的整图行，控制计算量
            let queryRows = query.tileRows
            for index in 0..<package.designs.count {
                let design = package.designs[index]
                guard let features = heavy.features(at: design.heavyOffset) else { continue }
                var best = 0.0
                let tileCount = features.tiles5.count / 384
                for row in queryRows {
                    for tile in 0..<tileCount {
                        let offset = tile * 384
                        var dot = 0.0
                        for i in 0..<384 {
                            dot += Double(row[i]) * Double(features.tiles5[offset + i])
                        }
                        if dot > best { best = dot }
                        if best >= 0.999 { break }
                    }
                }
                fineTiles[index] = best
            }
        }

        var ranked = candidates.sorted {
            let left = max($0.cls, $0.tile, fineTiles[$0.index] ?? 0, baseSims[$0.index] ?? 0)
            let right = max($1.cls, $1.tile, fineTiles[$1.index] ?? 0, baseSims[$1.index] ?? 0)
            return left > right
        }

        // 诊断：CLS 前 5 名（与 PC 对拍用）
        do {
            let top = ranked.prefix(5).map { item -> String in
                String(format: "%@(%.3f)", package.designs[item.index].code, item.cls)
            }
            let line = "CLS前5: " + top.joined(separator: " ")
            note += note.isEmpty ? line : "；" + line
        }

        // PC 式 SL 底布系列门控：先认底布（两位系列），再在系列内找绣花；不自信则回退全库
        let slEnabled = options.selectedLibraries.isEmpty
            || options.selectedLibraries.contains { $0.contains("SL") }
        if slEnabled, !query.clsRows.isEmpty {
            let slItems = ranked.filter { package.designs[$0.index].library.contains("SL") }
            if slItems.count >= 3 {
                var sums: [String: [Float]] = [:]
                var counts: [String: Int] = [:]
                package.withRecallPointer { base, _ in
                    for item in slItems {
                        let key = Self.slSeriesKey(package.designs[item.index].code)
                        if key.isEmpty { continue }
                        let record = base.advanced(by: item.index * GalleryPackage.recallFloats)
                        var mean = [Float](repeating: 0, count: GalleryPackage.dim)
                        for row in 0..<GalleryPackage.clsRows {
                            let ptr = record.advanced(by: row * GalleryPackage.dim)
                            for d in 0..<GalleryPackage.dim { mean[d] += ptr[d] }
                        }
                        for d in 0..<GalleryPackage.dim { mean[d] /= Float(GalleryPackage.clsRows) }
                        if sums[key] != nil {
                            for d in 0..<GalleryPackage.dim { sums[key]![d] += mean[d] }
                        } else {
                            sums[key] = mean
                        }
                        counts[key, default: 0] += 1
                    }
                }
                if sums.count >= 2 {
                    var scored: [(key: String, score: Double)] = []
                    for (key, total) in sums {
                        let divisor = Float(counts[key] ?? 1)
                        var proto = total.map { $0 / divisor }
                        var norm = 0.0
                        for value in proto { norm += Double(value * value) }
                        norm = norm.squareRoot()
                        if norm > 1e-9 { proto = proto.map { $0 / Float(norm) } }
                        var best = 0.0
                        for row in query.clsRows {
                            var dot = 0.0
                            for d in 0..<GalleryPackage.dim { dot += Double(row[d]) * Double(proto[d]) }
                            if dot > best { best = dot }
                        }
                        scored.append((key, best))
                    }
                    scored.sort { $0.score > $1.score }
                    let top = scored[0]
                    let gap = top.score - scored[1].score
                    if top.score >= 0.85, gap >= 0.02 {
                        let before = ranked.count
                        ranked = ranked.filter { item in
                            let design = package.designs[item.index]
                            if !design.library.contains("SL") { return true }
                            return Self.slSeriesKey(design.code) == top.key
                        }
                        note = "SL 底布 \(top.key) \(String(format: "%.3f", top.score)) 差\(String(format: "%.3f", gap))：\(before)→\(ranked.count)"
                    } else {
                        note = "SL 底布不确定 \(String(format: "%.3f", top.score)) 差\(String(format: "%.3f", gap))，回退全库"
                    }
                }
            }
        }
        timings.recallMs = Date().timeIntervalSince(recallStart) * 1000

        if shouldCancel() { throw InstallError.cancelled }

        // ---------- 2.5 PC 式召回：local5 保送 + base 保送 + dense 精排 ----------
        var aiScores: [Int: Double] = [:]
        do {
            progress("局部匹配…")

            // P0：local5（25 个细 tile 的最高分）前 60 名保送，不看综合排名。
            // PC: local_ids = argsort(local_scores)[:60] with score > 0.20
            let localOrdered = ranked.sorted {
                (fineTiles[$0.index] ?? 0) > (fineTiles[$1.index] ?? 0)
            }
            var localIds = Set<Int>()
            for item in localOrdered.prefix(60) where (fineTiles[item.index] ?? 0) > 0.20 {
                localIds.insert(item.index)
            }

            // P1：base 768 维前 30 保送（PC: BASE_RECALL_LIMIT = 30）
            let baseOrdered = ranked.sorted {
                (baseSims[$0.index] ?? 0) > (baseSims[$1.index] ?? 0)
            }
            var baseIds = Set<Int>()
            for item in baseOrdered.prefix(30) {
                baseIds.insert(item.index)
            }

            // 候选池 = 排名前 60 ∪ local 保送 ∪ base 保送
            var poolIds = Set(ranked.prefix(60).map { $0.index })
            poolIds.formUnion(localIds)
            poolIds.formUnion(baseIds)
            let pool = ranked.filter { poolIds.contains($0.index) }

            // dense：解码设计图 → 与查询同尺度的 patch（PC 的 dense_similarity）
            var denseWidth = 512
            var denseHeight = 512
            var denseScores: [Int: Double] = [:]
            if !query.patchRows.isEmpty {
                let step = max(1, query.patchRows.count / 96)
                let sampled = stride(from: 0, to: query.patchRows.count, by: step)
                    .map { query.patchRows[$0] }
                for item in pool {
                    let design = package.designs[item.index]
                    autoreleasepool {
                        guard let image = UIImage(contentsOfFile: package.imageURL(for: design).path),
                              let bytes = ImageOps.rgbaBytes(image, maxSide: 1280),
                              let canonical = CVImaging.canonicalRGBA(
                                  bytes.data,
                                  width: bytes.width,
                                  height: bytes.height,
                                  autoCrop: false,
                                  outWidth: &denseWidth,
                                  outHeight: &denseHeight
                              ),
                              let grayData = CVImaging.claheGray(
                                  fromRGBA: canonical,
                                  width: 512,
                                  height: 512
                              ) else { return }
                        let gray = PilImaging.GrayImage(
                            width: 512,
                            height: 512,
                            pixels: [UInt8](grayData)
                        )
                        guard let rows = try? encoder.designPatches(gray, fraction: 1.0),
                              !rows.isEmpty else { return }
                        var flat = [Float]()
                        flat.reserveCapacity(rows.count * 384)
                        for row in rows { flat.append(contentsOf: row) }
                        denseScores[item.index] = DenseMatch.similarity(
                            queryPatches: sampled,
                            designTiles: flat
                        )
                    }
                }
            }

            // PC: base_score = 0.20*cls + 0.80*dense；ai = 0.65*base_score + 0.35*tile
            //     ai = max(ai, 0.92*base_cls)
            for item in ranked {
                if poolIds.contains(item.index) {
                    let dense = denseScores[item.index] ?? 0
                    let baseScore = 0.20 * item.cls + 0.80 * dense
                    var ai = 0.65 * baseScore + 0.35 * item.tile
                    // base 只在最终公式里融合一次（PC 的做法），召回阶段不再抬升
                    aiScores[item.index] = ai
                } else {
                    // 未进池的保留粗分但压后，避免挤掉精排候选
                    aiScores[item.index] = 0.65 * item.cls + 0.35 * item.tile - 0.08
                }
            }
            ranked.sort { (aiScores[$0.index] ?? -1) > (aiScores[$1.index] ?? -1) }
        }

        // ---------- 3. base 重排 ----------
        // 候选池：深度复核扩到 100，否则 60（与 PC 一致）
        let poolLimit = options.deepReview ? 100 : 60
        let baseLimit = poolLimit
        // 普通搜索用 224（快），深度复试用 336（更准）
        let baseSize = options.deepReview ? 336 : 224
        var baseScores: [Int: Double] = [:]
        if ranked.count > 1 {
            progress("base 重排…")
            let baseStart = Date()
            if let baseQuery = try? encoder.encodeBase(enhancedGray: workingGray, size: baseSize) {
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
            // base 只在最终公式里融合一次（P1）
        }

        // ---------- 4. 组装结果 ----------
        let finalHits: [SearchHit] = ranked.prefix(poolLimit).map { item in
            let ai = aiScores[item.index] ?? Self.combined(item.cls, item.tile)
            let baseScore = baseScores[item.index] ?? 0
            return SearchHit(
                design: package.designs[item.index],
                score: ai,
                clsScore: item.cls,
                tileScore: item.tile,
                baseScore: baseScore,
                aiScore: ai
            )
        }

        // 深度复核：仅扩大候选池到 100（Vision/结构融合已移除，避免被最终公式覆盖）
        var finalList = finalHits

        // ---------- PC 最终打分：0.75 × aiComponent + 0.25 × oldScore ----------
        // 查询侧全局描述子（160 edge / fm / lbp / ori / radial / hu / stats）
        // PC 的 global_descriptor 输入是 structure map（512×512 边缘图），不是灰度图
        var structureBytes = Array(workingGray.pixels)
        if let canonical = canonicalBytes,
           let structure = CVImaging.structureMap(
               fromRGBA: canonical,
               width: 512,
               height: 512,
               size: 512
           ) {
            structureBytes = [UInt8](structure)
        }
        let globalQuery = PCGlobal.describe(structure: structureBytes, side: 512)

        // SIFT：查询（canonical）算一次；设计图解码后按 canonical 重算（精度优先）
        var siftScores: [Int: Double] = [:]
        let siftQueryImage: UIImage? = {
            if let canonical = canonicalBytes {
                return ImageOps.uiImageFromRGBA(canonical, width: 512, height: 512)
            }
            return queryImage
        }()
        if let siftQueryImage = siftQueryImage,
           let queryBytes = ImageOps.rgbaBytes(siftQueryImage),
           let queryFeatures = CVLocalMatcher.extractFeatures(
               queryBytes.data,
               width: queryBytes.width,
               height: queryBytes.height
           ) {
            let topForSift = Array(ranked.prefix(poolLimit))
            let indices = topForSift.map { $0.index }
            if !indices.isEmpty {
                let results = UnsafeMutablePointer<Double>.allocate(capacity: indices.count)
                results.initialize(repeating: 0, count: indices.count)
                DispatchQueue.concurrentPerform(iterations: indices.count) { slot in
                    let index = indices[slot]
                    let design = package.designs[index]
                    autoreleasepool {
                        let path = package.imageURL(for: design).path
                        let canonicalData: Data? = {
                            if let cached = DesignCanonicalCache.shared.image(path: path) {
                                return cached
                            }
                            guard let image = UIImage(contentsOfFile: path),
                                  let raw = ImageOps.rgbaBytes(image, maxSide: 1280) else { return nil }
                            var width = 512
                            var height = 512
                            guard let value = CVImaging.canonicalRGBA(
                                raw.data,
                                width: raw.width,
                                height: raw.height,
                                autoCrop: false,
                                outWidth: &width,
                                outHeight: &height
                            ) else { return nil }
                            DesignCanonicalCache.shared.store(path: path, data: value)
                            return value
                        }()
                        guard let canonical = canonicalData,
                              let designImage = ImageOps.uiImageFromRGBA(canonical, width: 512, height: 512),
                        let designBytes = ImageOps.rgbaBytes(designImage),
                        let designFeatures = CVLocalMatcher.extractFeatures(
                            designBytes.data,
                            width: designBytes.width,
                            height: designBytes.height
                        ) else { return }
                        results[slot] = CVLocalMatcher.match(queryFeatures, against: designFeatures)
                    }
                }
                for (slot, index) in indices.enumerated() {
                    siftScores[index] = results[slot]
                }
                results.deallocate()
            }
        }

        let refMap = LearningStore.shared.boostMap(queryRows: query.clsRows)

        // 学习样本强制入围：人工确认过的款即使不在前 N，也参与最终打分
        if !refMap.isEmpty {
            var existing = Set(finalList.map { $0.design.index })
            var byUUID: [String: DesignRef] = [:]
            for design in package.designs { byUUID[design.featureUUID] = design }
            for (uuid, ref) in refMap where ref >= 0.72 {
                guard let design = byUUID[uuid], !existing.contains(design.index) else { continue }
                guard let cand = candidates.first(where: { $0.index == design.index }) else { continue }
                finalList.append(SearchHit(
                    design: design,
                    score: 0,
                    clsScore: cand.cls,
                    tileScore: cand.tile,
                    baseScore: baseSims[design.index] ?? 0,
                    aiScore: ref
                ))
                existing.insert(design.index)
            }
        }

        var scored: [SearchHit] = []
        scored.reserveCapacity(finalList.count)
        for var hit in finalList {
            let index = hit.design.index
            guard let features = heavy?.features(at: hit.design.heavyOffset) else {
                scored.append(hit)
                continue
            }
            let sims = PCScoreFinal.compareGlobal(query: globalQuery, design: features)
            let edge = StructureScore.edgeCorrelation(
                globalQuery.edge.map { $0 / 255.0 },
                features.edge
            )
            let local = siftScores[index] ?? 0
            let old = PCScoreFinal.oldScore(local: local, edge: edge, stats: sims)

            var aiComp = PCScoreFinal.aiComponent(hit.aiScore)
            if let ref = refMap[hit.design.featureUUID], ref >= 0.72 {
                aiComp = PCScoreFinal.aiComponent(ref)
            }
            if hit.baseScore > 0 {
                aiComp = 0.70 * aiComp + 0.30 * PCScoreFinal.aiComponent(hit.baseScore)
            }
            hit.structureScore = old
            hit.score = min(0.995, max(0, 0.75 * aiComp + 0.25 * old))
            scored.append(hit)
        }
        finalList = scored.sorted { $0.score > $1.score }
        note += note.isEmpty ? "已按 PC 公式打分" : "；已按 PC 公式打分"

        timings.totalMs = Date().timeIntervalSince(started) * 1000
        if query.fromCache { note += note.isEmpty ? "查询特征命中缓存" : "；查询特征命中缓存" }
        return SearchOutcome(hits: Self.dedupeByCode(Array(finalList.prefix(max(1, options.resultCount)))), timings: timings, note: note)
    }

    /// 从编号里取出数字部分（SL9015 → 9015）
    /// 拆分编号为（字母前缀, 数字），如 SL1001 -> ("SL", 1001)、TM001 -> ("TM", 1)
    static func codePrefix(_ code: String) -> String {
        String(code.uppercased().prefix { !$0.isNumber })
    }

    static func codeNumber(_ code: String) -> Int? {
        let digits = code.compactMap { $0.isNumber ? $0 : nil }
        guard !digits.isEmpty else { return nil }
        return Int(String(digits))
    }

    // MARK: - 数学

    private static func combined(_ cls: Double, _ tile: Double) -> Double {
        tile <= 0 ? cls : cls * clsWeight + tile * tileWeight
    }

    /// 召回分与 dense 分融合（PC：AI_CLS 0.20 / AI_DENSE 0.80，这里把 cls+tile 当一路）
    static func blend(_ cls: Double, _ tile: Double, _ dense: Double?) -> Double {
        let base = combined(cls, tile)
        guard let dense = dense else { return base }
        return 0.25 * base + 0.75 * dense
    }

    /// 返回最佳余弦及其对应的目标行号（设计侧尺度）
    private static func bestCosineWithRow(
        queryRows: [[Float]],
        target: UnsafePointer<Float>,
        rows: Int
    ) -> (score: Double, row: Int) {
        var best = -1.0
        var bestRow = 0
        for row in queryRows {
            var queryNorm: Float = 0
            vDSP_svesq(row, 1, &queryNorm, vDSP_Length(dim))
            let normQ = Double(queryNorm).squareRoot()
            for r in 0..<rows {
                let pointer = target.advanced(by: r * dim)
                var dot: Float = 0
                vDSP_dotpr(row, 1, pointer, 1, &dot, vDSP_Length(dim))
                var targetNorm: Float = 0
                vDSP_svesq(pointer, 1, &targetNorm, vDSP_Length(dim))
                let value = Double(dot) / max(1e-9, normQ * Double(targetNorm).squareRoot())
                if value > best {
                    best = value
                    bestRow = r
                }
            }
        }
        return (max(0, best), bestRow)
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

    /// 同一款号只保留分数最高的一条（图库存在一款多图）
    static func dedupeByCode(_ hits: [SearchHit]) -> [SearchHit] {
        var seen = Set<String>()
        var output: [SearchHit] = []
        output.reserveCapacity(hits.count)
        for hit in hits where !seen.contains(hit.design.code) {
            seen.insert(hit.design.code)
            output.append(hit)
        }
        return output
    }

    /// SL 底布系列键：取编号前两位，如 SL30xxx -> "SL30"
    static func slSeriesKey(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.hasPrefix("SL") else { return "" }
        let digits = upper.dropFirst(2).prefix(2)
        guard digits.count == 2, digits.allSatisfy({ $0.isNumber }) else { return "" }
        return "SL" + digits
    }
}
