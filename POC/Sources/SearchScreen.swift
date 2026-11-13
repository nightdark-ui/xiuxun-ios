import SwiftUI
import UIKit

/// 系统相册/相机选择器
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/// 搜索状态
final class SearchModel: ObservableObject {
    @Published var busy = false
    @Published var progressText = ""
    @Published var hits: [SearchHit] = []
    @Published var timings: SearchTimings?
    @Published var note = ""
    @Published var errorText = ""
    @Published var queryThumb: UIImage?
    @Published var lastStep: String = ProbeTrace.last

    var options: SearchOptions { AppSettings.shared.makeOptions() }

    private var cancelRequested = false
    private var encoder: QueryEncoder?
    private var search: GallerySearch?
    private var packageIdentity = 0

    func cancel() {
        cancelRequested = true
        progressText = "正在取消…"
    }

    func prepare(package: GalleryPackage) {
        if search == nil || packageIdentity != package.count {
            search = GallerySearch(package: package)
            packageIdentity = package.count
        }
    }

    func run(image: UIImage, package: GalleryPackage) {
        guard !busy else { return }
        busy = true
        cancelRequested = false
        errorText = ""
        hits = []
        timings = nil
        note = ""
        progressText = "准备中…"
        queryThumb = image
        lastStep = ""
        ProbeTrace.clear()
        ProbeTrace.mark(.start)
        prepare(package: package)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("query-\(UUID().uuidString).jpg")
                guard let data = image.jpegData(compressionQuality: 0.95) else {
                    throw InstallError.verify("图片编码失败")
                }
                try data.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                ProbeTrace.mark(.gray)
                self.update("预处理…")
                let enhanced = try ImageOps.loadEnhancedGray(from: tempURL)

                ProbeTrace.mark(.loadSession)
                let encoder = try self.getEncoder()
                guard let search = self.search else { throw InstallError.verify("搜索器未就绪") }

                ProbeTrace.mark(.runModel)
                let outcome = try search.search(
                    enhancedGray: enhanced,
                    options: self.options,
                    encoder: encoder,
                    progress: { text in self.update(text) },
                    shouldCancel: { self.cancelRequested },
                    queryImage: image,
                    candidateImage: { design in
                        let url = package.thumbURL(for: design)
                        guard let data = try? Data(contentsOf: url) else { return nil }
                        return UIImage(data: data)
                    }
                )

                DispatchQueue.main.async {
                    self.hits = outcome.hits
                    self.timings = outcome.timings
                    self.note = outcome.note
                    self.busy = false
                    self.progressText = ""
                    self.queryThumb = image
                    self.lastStep = ""
                    ProbeTrace.clear()
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.progressText = ""
                    if case InstallError.cancelled = error {
                        self.note = "已取消搜索"
                    } else {
                        self.errorText = error.localizedDescription
                        self.lastStep = ProbeTrace.last
                    }
                }
            }
        }
    }

    private func update(_ text: String) {
        DispatchQueue.main.async { self.progressText = text }
    }

    private func getEncoder() throws -> QueryEncoder {
        if let encoder = encoder { return encoder }
        let created = try QueryEncoder(threads: DeviceInfo.savedBestThreads)
        encoder = created
        return created
    }
}

/// 搜索页（结构对齐安卓 AiSearchScreen）
struct SearchView: View {
    @ObservedObject var app: AppState
    @StateObject private var model = SearchModel()
    @ObservedObject private var settings = AppSettings.shared

    @State private var showPicker = false
    @State private var showCamera = false
    @State private var cropImage: UIImage?
    @State private var detail: SearchHit?
    @State private var showScope = false

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    private var resultOptions: [String] { ["30", "40", "60"] }
    private var resultIndex: Int {
        get { resultOptions.firstIndex(of: "\(settings.resultCount)") ?? 0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                BrandHeader()
                heroCard
                queryCard
                scopeCard
                codeRangeCard
                if model.busy { progressCard }
                if !model.errorText.isEmpty { errorCard }
                if let timings = model.timings { resultHeader(timings) }
                if !model.hits.isEmpty { manualCard }
                resultGrid
                if !model.hits.isEmpty { deepReviewAgain }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .background(UI.pageBackground.ignoresSafeArea())
        .sheet(isPresented: $showPicker) {
            ImagePicker(sourceType: .photoLibrary) { cropImage = $0 }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { cropImage = $0 }
        }
        .sheet(isPresented: Binding(
            get: { cropImage != nil },
            set: { if !$0 { cropImage = nil } }
        )) {
            if let image = cropImage {
                CropScreen(image: image) { picked in
                    if let package = app.package { model.run(image: picked, package: package) }
                    cropImage = nil
                }
            }
        }
        .sheet(isPresented: $showScope) {
            ScopeSheet(app: app)
        }
        .sheet(isPresented: Binding(
            get: { detail != nil },
            set: { if !$0 { detail = nil } }
        )) {
            if let hit = detail {
                ResultDetail(hit: hit, package: app.package, queryImage: model.queryThumb)
            }
        }
    }

    // MARK: - 卡片

    private var heroCard: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("—— PICSEEK / 花型检索")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(UI.orange)
                Text("PicSeek，AI搜图。")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(UI.textPrimary)
                Text("上传客户来图，秒找对应花型")
                    .font(.system(size: 12))
                    .foregroundColor(UI.textSecondary)
            }
            Spacer()
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 34))
                .foregroundColor(UI.orange.opacity(0.85))
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: [UI.orange.opacity(0.16), UI.orange.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
    }

    private var queryCard: some View {
        AppCard {
            CardHeader(title: "客户来图")
            DashedBox {
                if let thumb = model.queryThumb {
                    Image(uiImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 130)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 40))
                        .foregroundColor(UI.orange.opacity(0.75))
                        .padding(.top, 6)
                    Text("上传客户来图")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(UI.textPrimary)
                        .padding(.top, 2)
                    Text("点击选择图片\n相册、拍照、截图都可以")
                        .font(.system(size: 11))
                        .foregroundColor(UI.textSecondary)
                        .multilineTextAlignment(.center)
                    Text("颜色自动忽略 · 局部 / 整图都可")
                        .font(.system(size: 10))
                        .foregroundColor(UI.orange.opacity(0.85))
                }
                HStack(spacing: 10) {
                    Button { showPicker = true } label: {
                        Text("选择图片").font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(UI.orange).foregroundColor(.white).clipShape(Capsule())
                    }
                    Button { showCamera = true } label: {
                        Text("拍照").font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(UI.cardBackground)
                            .foregroundColor(UI.orange)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(UI.orange.opacity(0.6), lineWidth: 1))
                    }
                }
                .disabled(model.busy)
                .padding(.horizontal, 10)
            }
            .contentShape(Rectangle())
            .onTapGesture { if !model.busy { showPicker = true } }
        }
    }

    private var scopeCard: some View {
        AppCard {
            CardHeader(title: "搜索范围", trailing: settings.libraryFilter.isEmpty ? "全部图库" : "已选 \(settings.libraryFilter.count) 个库")
            HStack {
                Text("结果数量").font(.system(size: 13)).foregroundColor(UI.textPrimary)
                Spacer()
                Segmented(options: resultOptions, selected: Binding(
                    get: { resultIndex },
                    set: { settings.resultCount = Int(resultOptions[$0]) ?? 30 }
                ))
                .frame(width: 150)
            }
            if !app.libraries.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("按图库筛选").font(.system(size: 13)).foregroundColor(UI.textPrimary)
                        Spacer()
                        Button {
                            settings.libraryFilter = []
                        } label: {
                            Text(settings.libraryFilter.isEmpty ? "全部" : "清空")
                                .font(.system(size: 12))
                                .foregroundColor(UI.orange)
                        }
                        .buttonStyle(.plain)
                        .disabled(settings.libraryFilter.isEmpty)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], spacing: 6) {
                        ForEach(Array(app.libraryInfos.enumerated()), id: \.offset) { pair in
                            libraryChip(pair.element)
                        }
                    }
                    Toggle("局部来图优先", isOn: $settings.localFirst)
                        .font(.system(size: 13))
                }
                .disabled(model.busy)
            }
        }
    }


    /// 单个图库筛选 chip
    private func libraryChip(_ item: LibraryInfo) -> some View {
        let selected = settings.libraryFilter.contains(item.name)
        return Button {
            if selected {
                settings.libraryFilter.remove(item.name)
            } else {
                settings.libraryFilter.insert(item.name)
            }
        } label: {
            Text("\(item.name) \(item.count)")
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(selected ? UI.orange.opacity(0.14) : UI.cardBackground)
                .foregroundColor(selected ? UI.orange : UI.textSecondary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(selected ? UI.orange.opacity(0.5) : Color.black.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(model.busy)
    }

    private var codeRangeCard: some View {
        AppCard {
            CardHeader(title: "编号范围", trailing: "可留空")
            HStack(spacing: 6) {
                TextField("如 SL9000", text: $settings.codeFrom)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
                Text("—").foregroundColor(UI.textSecondary)
                TextField("如 SL9999", text: $settings.codeTo)
                    .textFieldStyle(.roundedBorder)
                    .autocapitalization(.allCharacters)
                    .disableAutocorrection(true)
            }
            Hint(text: "只搜这个编号区间内的款；留空表示不限制")
        }
    }

    private var progressCard: some View {
        AppCard {
            HStack(spacing: 10) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.progressText.isEmpty ? "搜索中…" : model.progressText)
                        .font(.system(size: 13)).foregroundColor(UI.textPrimary)
                    if !model.lastStep.isEmpty {
                        Text("当前阶段：\(model.lastStep)")
                            .font(.system(size: 10)).foregroundColor(UI.textSecondary)
                    }
                }
                Spacer()
                Button(role: .destructive) { model.cancel() } label: {
                    Text("取消").font(.system(size: 12))
                }
            }
        }
    }

    private var errorCard: some View {
        AppCard {
            Text(model.errorText)
                .font(.system(size: 12))
                .foregroundColor(.red)
            if !model.lastStep.isEmpty {
                Text("中断于：\(model.lastStep)")
                    .font(.system(size: 10)).foregroundColor(UI.textSecondary)
            }
        }
    }

    private func resultHeader(_ timings: SearchTimings) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("找到 \(model.hits.count) 个结果")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(UI.textPrimary)
                Spacer()
                Text(String(format: "用时 %.1f 秒", timings.totalMs / 1000))
                    .font(.system(size: 12))
                    .foregroundColor(UI.textSecondary)
            }
            if lastConfirmedSampleID != nil {
                Button { undoLearning() } label: {
                    Text("撤回上次确认").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundColor(UI.orange)
            }
            if !model.note.isEmpty {
                Text(model.note)
                    .font(.system(size: 11))
                    .foregroundColor(UI.textSecondary)
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var resultGrid: some View {
        if model.hits.isEmpty {
            if !model.busy {
                VStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.badge.magnifyingglass")
                        .font(.system(size: 30)).foregroundColor(UI.textSecondary.opacity(0.5))
                    Text("还没有结果").font(.system(size: 12)).foregroundColor(UI.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(Array(model.hits.enumerated()), id: \.offset) { index, hit in
                    Button { detail = hit } label: {
                        resultCell(hit: hit, rank: index + 1)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @State private var lastConfirmedCode: String?
    @State private var lastConfirmedSampleID: String?

    /// 撤回最近一次确认
    private func undoLearning() {
        guard let sampleID = lastConfirmedSampleID else { return }
        _ = LearningStore.shared.removeSample(sampleID: sampleID)
        model.note = "已撤回确认：\(lastConfirmedCode ?? "")"
        lastConfirmedSampleID = nil
        lastConfirmedCode = nil
    }

    /// 记录「确认是这款」：把当前查询特征绑定到这一款
    private func confirmLearning(hit: SearchHit) {
        guard let features = QueryEncoder.lastFeatures else { return }
        let cls = features.clsRows.flatMap { $0 }
        let tiles = features.tileRows.flatMap { $0 }
        _ = LearningStore.shared.addSample(
            featureUUID: hit.design.featureUUID,
            cls: cls,
            tiles: tiles
        )
        lastConfirmedCode = hit.design.code
        lastConfirmedSampleID = LearningStore.shared.lastAddedSampleID
        model.note = "已记录学习样本：\(hit.design.code)（可点「撤回」撤销）"
    }

    @State private var manualCode = ""
    @State private var pendingDesign: DesignRef?

    /// 结果里没有正确款时，手动输入款号确认
    private var manualCard: some View {
        AppCard {
            CardHeader(title: "没找到？手动确认")
            HStack(spacing: 8) {
                TextField("输入款号，如 9008", text: $manualCode)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                Button("查图") { lookupManual() }
                    .buttonStyle(.plain)
                    .foregroundColor(UI.orange)
                    .font(.system(size: 13, weight: .semibold))
            }
            if let pending = pendingDesign {
                HStack(spacing: 10) {
                    CachedThumb(url: app.package?.thumbURL(for: pending), height: 72)
                        .frame(width: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(pending.code).font(.system(size: 14, weight: .semibold))
                        Button("确认是这款") { confirmPending() }
                            .buttonStyle(.plain)
                            .foregroundColor(UI.orange)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Spacer()
                }
            }
            if lastConfirmedSampleID != nil {
                Button("撤回上次确认") { undoLearning() }
                    .buttonStyle(.plain)
                    .foregroundColor(UI.orange)
                    .font(.system(size: 12))
            }
            if !model.note.isEmpty {
                Text(model.note).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    /// 第一步：按款号查出该款并预览
    private func lookupManual() {
        let code = manualCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        guard let design = app.package?.designs.first(where: { $0.code == code }) else {
            pendingDesign = nil
            model.note = "图库里没有款号 \(code)"
            return
        }
        pendingDesign = design
        model.note = "确认是 \(design.code) 吗？"
    }

    /// 第二步：确认加入学习
    private func confirmPending() {
        guard let design = pendingDesign, let features = QueryEncoder.lastFeatures else {
            model.note = "请先搜索一次，再手动确认"
            return
        }
        let cls = features.clsRows.flatMap { $0 }
        let tiles = features.tileRows.flatMap { $0 }
        _ = LearningStore.shared.addSample(featureUUID: design.featureUUID, cls: cls, tiles: tiles)
        lastConfirmedCode = design.code
        lastConfirmedSampleID = LearningStore.shared.lastAddedSampleID
        model.note = "已记录学习样本：\(design.code)（可撤回）"
        pendingDesign = nil
        manualCode = ""
    }

    /// 结果不满意时，用深度复核（100 候选 + base336）再搜一次
    private var deepReviewAgain: some View {
        VStack(spacing: 6) {
            Button {
                guard let image = model.queryThumb else { return }
                settings.deepReview = true
                if let package = app.package { model.run(image: image, package: package) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise.circle")
                        .font(.system(size: 14, weight: .semibold))
                    Text(model.busy ? "正在深度复核…" : "结果不满意？用深度复核再搜一次")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(UI.orange.opacity(0.12))
                .foregroundColor(UI.orange)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(model.busy || model.queryThumb == nil)

            Text("深度复核：候选 100 个，base 336 输入，更准但慢约 40%")
                .font(.system(size: 10))
                .foregroundColor(UI.textSecondary)
        }
        .padding(.top, 6)
    }

    private func resultCell(hit: SearchHit, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                CachedThumb(url: app.package?.thumbURL(for: hit.design), height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text("\(rank)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(rank == 1 ? UI.orange : Color.black.opacity(0.55))
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .padding(5)
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text(String(format: "%.0f%%", hit.score * 100))
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(5)
                    }
                }
            }
            Text(hit.design.code.isEmpty ? hit.design.title : hit.design.code)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(UI.textPrimary)
                .lineLimit(1)
            Text(hit.design.library)
                .font(.system(size: 10))
                .foregroundColor(UI.textSecondary)
                .lineLimit(1)
        }
        .padding(6)
        .background(UI.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(UI.divider, lineWidth: 0.6)
        )
    }
}

/// 图库筛选弹窗
struct ScopeSheet: View {
    @ObservedObject var app: AppState
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                ForEach(app.libraries, id: \.name) { item in
                    Button {
                        if settings.libraryFilter.contains(item.name) {
                            settings.libraryFilter.remove(item.name)
                        } else {
                            settings.libraryFilter.insert(item.name)
                        }
                    } label: {
                        HStack {
                            Text(item.name).foregroundColor(UI.textPrimary)
                            Spacer()
                            Text("\(item.count)").foregroundColor(UI.textSecondary)
                            if settings.libraryFilter.contains(item.name) {
                                Image(systemName: "checkmark").foregroundColor(UI.orange)
                            }
                        }
                    }
                }
                Section {
                    Button("清空（搜全部图库）") { settings.libraryFilter.removeAll() }
                        .foregroundColor(UI.orange)
                }
            }
            .navigationTitle("按图库筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

extension SearchHit: Identifiable {
    var id: Int { design.index }
}

/// 结果详情（含保存/分享）
struct ResultDetail: View {
    let hit: SearchHit
    let package: GalleryPackage?
    let queryImage: UIImage?
    @State private var candidateImage: UIImage?
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: UIImage?
    @State private var detailNote = ""
    @State private var lastConfirmedSampleID: String?

    private func confirmFromDetail() {
        guard let features = QueryEncoder.lastFeatures else {
            detailNote = "请先完成一次搜索"
            return
        }
        let cls = features.clsRows.flatMap { $0 }
        let tiles = features.tileRows.flatMap { $0 }
        _ = LearningStore.shared.addSample(featureUUID: hit.design.featureUUID, cls: cls, tiles: tiles)
        lastConfirmedSampleID = LearningStore.shared.lastAddedSampleID
        detailNote = "已记录学习样本：\(hit.design.code)"
    }

    private func undoFromDetail() {
        guard let id = lastConfirmedSampleID else { return }
        _ = LearningStore.shared.removeSample(sampleID: id)
        lastConfirmedSampleID = nil
        detailNote = "已撤回"
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let package = package {
                        AsyncImage(url: package.imageURL(for: hit.design)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                AsyncImage(url: package.thumbURL(for: hit.design)) { thumb in
                                    if let image = thumb.image {
                                        image.resizable().aspectRatio(contentMode: .fit)
                                    } else {
                                        ProgressView().frame(height: 220)
                                    }
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(hit.design.code.isEmpty ? hit.design.title : hit.design.code)
                                .font(.system(size: 18, weight: .bold))
                            Text(hit.design.library)
                                .font(.system(size: 12)).foregroundColor(UI.textSecondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f", hit.score * 100))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(UI.orange)
                    }

                    AppCard {
                        VStack(spacing: 8) {
                            Button {
                                confirmFromDetail()
                            } label: {
                                Text("确认是这款")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .background(UI.orange)
                                    .foregroundColor(.white)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            if lastConfirmedSampleID != nil {
                                Button("撤回上次确认") { undoFromDetail() }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12))
                                    .foregroundColor(UI.orange)
                            }
                            if !detailNote.isEmpty {
                                Text(detailNote)
                                    .font(.system(size: 11))
                                    .foregroundColor(UI.textSecondary)
                            }
                        }
                    }

                    AppCard {
                        row("CLS", String(format: "%.3f", hit.clsScore))
                        row("tile", String(format: "%.3f", hit.tileScore))
                        row("base", hit.baseScore > 0 ? String(format: "%.3f", hit.baseScore) : "未参与")
                    }

                    ScoresPanel(
                        queryImage: queryImage,
                        candidateImage: candidateImage,
                        dinoScore: hit.score
                    )

                    HStack(spacing: 10) {
                        PrimaryButton(title: "分享 / 保存") { loadImage() }
                        Button {
                            loadImage()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .semibold))
                                .padding(.vertical, 13).padding(.horizontal, 18)
                                .background(UI.orange.opacity(0.12))
                                .foregroundColor(UI.orange)
                                .clipShape(Capsule())
                        }
                        .hidden()
                    }
                }
                .padding(16)
            }
            .background(UI.pageBackground.ignoresSafeArea())
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
            .task {
                guard let package = package, candidateImage == nil else { return }
                let url = package.imageURL(for: hit.design)
                DispatchQueue.global().async {
                    if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
                        DispatchQueue.main.async { candidateImage = image }
                    }
                }
            }
            .sheet(item: Binding(
                get: { shareItem.map(ShareBox.init) },
                set: { if $0 == nil { shareItem = nil } }
            )) { box in
                ShareSheet(items: [box.image])
            }
        }
    }

    private func loadImage() {
        guard let package = package else { return }
        DispatchQueue.global().async {
            if let data = try? Data(contentsOf: package.imageURL(for: hit.design)),
               let image = UIImage(data: data) {
                DispatchQueue.main.async { shareItem = image }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundColor(UI.textSecondary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(UI.textPrimary)
        }
    }
}

struct ShareBox: Identifiable {
    let image: UIImage
    var id: ObjectIdentifier { ObjectIdentifier(image) }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
