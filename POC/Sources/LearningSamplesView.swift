import SwiftUI

/// 学习样本管理：列出已确认/导入的样本，可左滑或点垃圾桶删除，可一键清空
struct LearningSamplesView: View {
    @ObservedObject private var store = LearningStore.shared
    @ObservedObject var app: AppState
    @State private var confirmClear = false

    private func code(for uuid: String) -> String? {
        app.package?.designs.first(where: { $0.featureUUID == uuid })?.code
    }

    private func library(for uuid: String) -> String? {
        app.package?.designs.first(where: { $0.featureUUID == uuid })?.library
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("本地样本")
                    Spacer()
                    Text("\(store.totalSamples) 条")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("内置样本")
                    Spacer()
                    Text("\(store.bundledCount) 条（\(store.bundledUUIDCount) 款）")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("合计覆盖")
                    Spacer()
                    Text("\(store.uuidCount) 款")
                        .foregroundColor(UI.orange)
                }
            } footer: {
                Text("内置样本打包在 App 里，不可删除；本地样本是你确认或导入的，可删除。")
                    .font(.system(size: 11))
            }

            if store.samples.isEmpty {
                Section {
                    Text("还没有本地样本")
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
                                    Text("· \(sample.clsRows) 行")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.samples[$0].sampleID }
                        for id in ids { _ = store.removeSample(sampleID: id) }
                    }
                } header: {
                    Text("本地样本（左滑可删除）")
                } footer: {
                    Text("删除后该款不再享受学习加成，立即生效。")
                        .font(.system(size: 11))
                }

                Section {
                    Button(role: .destructive) {
                        confirmClear = true
                    } label: {
                        Text("清空全部本地样本")
                    }
                }
            }
        }
        .navigationTitle("学习样本")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "确定清空全部本地样本？",
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button("清空 \(store.totalSamples) 条（不可恢复）", role: .destructive) {
                store.clear()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("内置样本不受影响。")
        }
    }
}
