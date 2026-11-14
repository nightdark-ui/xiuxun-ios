import SwiftUI

/// 学习样本管理：列出已确认的样本，可逐条删除
struct LearningSamplesView: View {
    @ObservedObject private var store = LearningStore.shared
    @ObservedObject var app: AppState

    private func code(for uuid: String) -> String? {
        app.package?.designs.first(where: { $0.featureUUID == uuid })?.code
    }

    private func library(for uuid: String) -> String? {
        app.package?.designs.first(where: { $0.featureUUID == uuid })?.library
    }

    var body: some View {
        List {
            if store.samples.isEmpty {
                Section {
                    Text("还没有学习样本")
                        .foregroundColor(.secondary)
                    Text("在搜索结果第 11 名以后点「确认是这款」，或在搜索页手动输入款号确认。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
            } else {
                Section {
                    ForEach(store.samples, id: \.sampleID) { sample in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(code(for: sample.featureUUID) ?? String(sample.featureUUID.prefix(8)))
                                    .font(.system(size: 16, weight: .semibold))
                                HStack(spacing: 6) {
                                    Text(library(for: sample.featureUUID) ?? "未知库")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Text("· 条 \(sample.sampleID.suffix(6))")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    Text("· \(sample.clsRows) 行")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                _ = store.removeSample(sampleID: sample.sampleID)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("删除后该款不再享受学习加成，立即生效。")
                        .font(.system(size: 11))
                }
            }

            Section {
                Text("内置样本 \(store.bundledCount) 条（打包在 App 里，不可删除）")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("学习样本")
        .navigationBarTitleDisplayMode(.inline)
    }
}
