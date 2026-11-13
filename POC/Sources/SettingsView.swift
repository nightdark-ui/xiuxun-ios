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
        options.rotationEnabled = rotationEnabled
        options.mirrorEnabled = mirrorEnabled
        options.fastMode = false   // 已移除快速模式：只转 4 角度会影响精度
        options.deepReview = deepReview
        options.resultCount = deepReview ? max(100, resultCount) : resultCount
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
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                BrandHeader()
            }
            Section {
                Toggle("深度复核（更准、更慢）", isOn: $settings.deepReview)
                Toggle("自动裁切主体", isOn: $settings.autoCrop)
                Toggle("循环花型增强（实验，较慢）", isOn: $settings.allowRepeat)
                Toggle("局部来图优先", isOn: $settings.localFirst)
                Toggle("旋转搜索（8 个角度）", isOn: $settings.rotationEnabled)
                Toggle("镜像搜索（更慢，默认关）", isOn: $settings.mirrorEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("识别严格度").font(.system(size: 14))
                    Segmented(
                        options: ["精准", "均衡", "宽松"],
                        selected: Binding(
                            get: { settings.strictness },
                            set: { settings.strictness = $0 }
                        )
                    )
                }
            } header: {
                Text("搜索")
            } footer: {
                Text("深度复核：候选 120、base 336，单次约 25–30 秒；普通搜索约 13–15 秒。")
                    .font(.caption2)
            }

            Section {
                Toggle("base 用 336（PC 原口径）", isOn: $settings.base336)
            } header: {
                Text("相似度")
            } footer: {
                Text("224 快但 Top5 顺序与 PC 有差异；336 更接近 PC，每次多 2–3 秒。")
                    .font(.caption2)
            }

            Section {
            } header: {
                Text("结果")
            }

            DiagnoseSection()
            GalleryLocationSection()
            LearningSection()

            Section {
                Text(DeviceInfo.summary).font(.caption2)
                Text("线程数在「图库 → 性能诊断」里标定，保存后自动生效")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } header: {
                Text("设备")
            }
        }
        .navigationTitle("设置")
    }
}


/// 学习包：导入 / 导出 / 统计
struct LearningSection: View {
    @State private var importing = false
    @State private var exporting = false
    @State private var message = ""
    @State private var exportURL: URL?

    var body: some View {
        Section {
            HStack {
                Text("学习样本")
                Spacer()
                Text("\(LearningStore.shared.totalSamples) 个 / \(LearningStore.shared.uuidCount) 款")
                    .foregroundColor(.secondary)
            }

            Button("导出学习包") { doExport() }
                .disabled(LearningStore.shared.totalSamples == 0)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("参考学习")
        } footer: {
            Text("参考学习已内置 \(LearningStore.shared.bundledCount) 条样本；命中时按 max(AI, 学习分) 抬升，不降权。")
                .font(.caption2)
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let gained = url.startAccessingSecurityScopedResource()
                defer { if gained { url.stopAccessingSecurityScopedResource() } }
                do {
                    let outcome = try LearningStore.shared.importPack(from: url)
                    message = outcome.message
                } catch {
                    message = "导入失败：\(error.localizedDescription)"
                }
            case .failure(let error):
                message = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $exporting) {
            if let url = exportURL {
                ShareSheet(items: [url])
            }
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
            exportURL = url
            exporting = true
            message = "已导出 \(count) 个样本"
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
