import SwiftUI
import Foundation
import Combine

/// 用户设置（UserDefaults 持久化）
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var deepReview: Bool {
        didSet { UserDefaults.standard.set(deepReview, forKey: "set.deepReview") }
    }
    @Published var rotationEnabled: Bool {
        didSet { UserDefaults.standard.set(rotationEnabled, forKey: "set.rotation") }
    }
    @Published var mirrorEnabled: Bool {
        didSet { UserDefaults.standard.set(mirrorEnabled, forKey: "set.mirror") }
    }
    @Published var base336: Bool {
        didSet { UserDefaults.standard.set(base336, forKey: "set.base336") }
    }
    @Published var diagnosticCode: String = ""
    @Published var allowRepeat: Bool {
        didSet { UserDefaults.standard.set(allowRepeat, forKey: "set.allowRepeat") }
    }
    @Published var autoCrop: Bool {
        didSet { UserDefaults.standard.set(autoCrop, forKey: "set.autoCrop") }
    }
    @Published var localFirst: Bool {
        didSet { UserDefaults.standard.set(localFirst, forKey: "set.localFirst") }
    }
    @Published var strictness: Int {
        didSet { UserDefaults.standard.set(strictness, forKey: "set.strictness") }
    }
    @Published var libraryFilter: Set<String> {
        didSet { UserDefaults.standard.set(Array(libraryFilter), forKey: "set.libraryFilter") }
    }
    @Published var codeFrom: String {
        didSet { UserDefaults.standard.set(codeFrom, forKey: "set.codeFrom") }
    }
    @Published var codeTo: String {
        didSet { UserDefaults.standard.set(codeTo, forKey: "set.codeTo") }
    }
    @Published var resultCount: Int {
        didSet { UserDefaults.standard.set(resultCount, forKey: "set.resultCount") }
    }

    private init() {
        let defaults = UserDefaults.standard
        deepReview = defaults.bool(forKey: "set.deepReview")
        rotationEnabled = defaults.object(forKey: "set.rotation") as? Bool ?? true
        mirrorEnabled = defaults.bool(forKey: "set.mirror")
        base336 = defaults.object(forKey: "set.base336") as? Bool ?? true
        allowRepeat = defaults.bool(forKey: "set.allowRepeat")
        autoCrop = defaults.object(forKey: "set.autoCrop") as? Bool ?? true
        localFirst = defaults.bool(forKey: "set.localFirst")
        strictness = defaults.object(forKey: "set.strictness") as? Int ?? 1
        libraryFilter = Set(defaults.stringArray(forKey: "set.libraryFilter") ?? [])
        codeFrom = defaults.string(forKey: "set.codeFrom") ?? ""
        codeTo = defaults.string(forKey: "set.codeTo") ?? ""
        let count = defaults.integer(forKey: "set.resultCount")
        resultCount = count > 0 ? count : 60
    }

    func makeOptions() -> SearchOptions {
        var options = SearchOptions()
        options.rotationEnabled = true
        options.mirrorEnabled = mirrorEnabled
        options.fastMode = false   // 已移除快速模式：只转 4 角度会影响精度
        options.deepReview = deepReview
        options.resultCount = deepReview ? 100 : 60
        options.baseInputSize = 336
        options.selectedLibraries = libraryFilter
        options.diagnosticCode = diagnosticCode
        options.allowRepeat = allowRepeat
        options.autoCrop = autoCrop
        options.localFirst = localFirst
        options.strictness = strictness
        options.codeFrom = codeFrom.trimmingCharacters(in: .whitespaces)
        options.codeTo = codeTo.trimmingCharacters(in: .whitespaces)
        return options
    }
}

struct SettingsView: View {
    @ObservedObject var app: AppState
    @ObservedObject private var settings = AppSettings.shared
    @State private var showProbe = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                BrandHeader()

                group("搜索") {
                    Toggle("base 输入 336（PC 原口径）", isOn: $settings.base336)
                        .font(.system(size: 15))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }

                group("参考学习") { LearningSection() }

                group("诊断") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("诊断款号").font(.system(size: 15)).foregroundColor(UI.textPrimary)
                        TextField("如 10464（留空关闭）", text: $settings.diagnosticCode)
                            .font(.system(size: 14))
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.characters)
                        Text("填入后，搜索结果下方会显示该款的召回与最终排名")
                            .font(.system(size: 11))
                            .foregroundColor(UI.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)

                    Divider().padding(.leading, 14)

                    Button { showProbe = true } label: {
                        row("性能诊断", value: "线程数 \(DeviceInfo.savedBestThreads)")
                    }
                    .buttonStyle(.plain)
                }

                group("关于") {
                    row("版本", value: "\(AppInfo.version) · 构建 \(AppInfo.build)")
                    Divider().padding(.leading, 14)
                    row("设备", value: "\(DeviceInfo.machine) · \(DeviceInfo.coreCount) 核")
                }

                GalleryLocationSection()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(UI.pageBackground.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showProbe) { ProbePanelView() }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(UI.textSecondary)
                .padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func row(_ title: String, value: String? = nil) -> some View {
        HStack {
            Text(title).font(.system(size: 15)).foregroundColor(UI.textPrimary)
            Spacer()
            if let value {
                Text(value).font(.system(size: 13)).foregroundColor(UI.textSecondary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(UI.textSecondary.opacity(0.55))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}


/// 学习包：导入 / 导出 / 统计
struct LearningSection: View {
    @State private var message = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("学习样本").font(.system(size: 15)).foregroundColor(UI.textPrimary)
                Spacer()
                Text("\(LearningStore.shared.totalSamples) 个 / \(LearningStore.shared.uuidCount) 款")
                    .font(.system(size: 13))
                    .foregroundColor(UI.textSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)

            Divider().padding(.leading, 14)

            Button {
                doExport()
            } label: {
                HStack {
                    Text("导出学习包").font(.system(size: 15)).foregroundColor(UI.textPrimary)
                    Spacer()
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 14))
                        .foregroundColor(UI.textSecondary.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(LearningStore.shared.totalSamples == 0)

            if !message.isEmpty {
                Divider().padding(.leading, 14)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(UI.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider().padding(.leading, 14)

            Text("内置 \(LearningStore.shared.bundledCount) 条样本；命中时按 max(AI, 学习分) 抬升，不降权。")
                .font(.system(size: 11))
                .foregroundColor(UI.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
    }

    private func doExport() {
        let documents = (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = documents.appendingPathComponent("PicSeek-Learning.zip")
        do {
            let count = try LearningStore.shared.exportPack(to: url)
            message = "已导出 \(count) 个样本：\(url.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}


/// 图库文件夹：手动指定（放「我的 iPhone」自定义文件夹里）
struct GalleryLocationSection: View {
    @State private var picking = false
    @State private var message = ""

    private var currentPath: String {
        if let url = GalleryInstaller.customRoot { return url.lastPathComponent }
        return "默认（PicSeek/Gallery）"
    }

    var body: some View {
        AppCard {
            CardHeader(title: "图库文件夹")
            Text(currentPath).font(.system(size: 12)).foregroundStyle(.secondary)
            Button("选择图库文件夹") { picking = true }
                .buttonStyle(.plain)
                .foregroundStyle(UI.orange)
            if !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Hint(text: "选「我的 iPhone」里存放图库的文件夹（需含 index.json / recall.bin / heavy.bin / images）")
        }
        .fileImporter(
            isPresented: $picking,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let index = url.appendingPathComponent("index.json")
                guard FileManager.default.fileExists(atPath: index.path) else {
                    message = "该文件夹里没有 index.json"
                    return
                }
                GalleryInstaller.customRoot = url
                GalleryInstaller.beginCustomAccess()
                NotificationCenter.default.post(name: .galleryRootChanged, object: nil)
                message = "已设为：\(url.lastPathComponent)"
            case .failure(let error):
                message = "选择失败：\(error.localizedDescription)"
            }
        }
    }
}


extension Notification.Name {
    static let galleryRootChanged = Notification.Name("galleryRootChanged")
}


/// 诊断：输入款号，搜索时输出该款在召回/最终排序中的位置
struct DiagnoseSection: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        AppCard {
            CardHeader(title: "诊断")
            TextField("输入款号，如 10464", text: $settings.diagnosticCode)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Hint(text: "填了款号后，搜索结果备注里会显示该款的召回排名/最终排名和各项分数；留空即关闭")
        }
    }
}
