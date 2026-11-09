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
    @Published var resultCount: Int {
        didSet { UserDefaults.standard.set(resultCount, forKey: "set.resultCount") }
    }

    private init() {
        let defaults = UserDefaults.standard
        deepReview = defaults.bool(forKey: "set.deepReview")
        rotationEnabled = defaults.object(forKey: "set.rotation") as? Bool ?? true
        mirrorEnabled = defaults.bool(forKey: "set.mirror")
        base336 = defaults.bool(forKey: "set.base336")
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
        return options
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("深度复核（更准、更慢）", isOn: $settings.deepReview)
                Toggle("旋转搜索（8 个角度）", isOn: $settings.rotationEnabled)
                Toggle("镜像搜索（更慢，默认关）", isOn: $settings.mirrorEnabled)
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
