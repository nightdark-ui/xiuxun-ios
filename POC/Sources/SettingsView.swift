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
        base336 = defaults.bool(forKey: "set.base336")
        allowRepeat = defaults.bool(forKey: "set.allowRepeat")
        autoCrop = defaults.object(forKey: "set.autoCrop") as? Bool ?? true
        localFirst = defaults.bool(forKey: "set.localFirst")
        strictness = defaults.object(forKey: "set.strictness") as? Int ?? 1
        libraryFilter = Set(defaults.stringArray(forKey: "set.libraryFilter") ?? [])
        codeFrom = defaults.string(forKey: "set.codeFrom") ?? ""
        codeTo = defaults.string(forKey: "set.codeTo") ?? ""
        let count = defaults.integer(forKey: "set.resultCount")
        resultCount = count > 0 ? count : 30
    }

    func makeOptions() -> SearchOptions {
        var options = SearchOptions()
        options.rotationEnabled = rotationEnabled
        options.mirrorEnabled = mirrorEnabled
        options.fastMode = false   // 已移除快速模式：只转 4 角度会影响精度
        options.deepReview = deepReview
        options.resultCount = resultCount
        options.baseInputSize = base336 ? 336 : 224
        options.selectedLibraries = libraryFilter
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
                Stepper("结果数量：\(settings.resultCount)", value: $settings.resultCount, in: 10...60, step: 10)
            } header: {
                Text("结果")
            }

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

            Button("导入学习包（.zip）") { importing = true }
            Button("导出学习包") { doExport() }
                .disabled(LearningStore.shared.totalSamples == 0)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        } header: {
            Text("参考学习")
        } footer: {
            Text("导入后，命中的款会按 85% AI 分 + 15% 学习分重排；没有样本的款不受影响。")
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
