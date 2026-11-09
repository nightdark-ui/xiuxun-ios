import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    private var isBusy: Bool { runner.phase == .running }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成业绣 iOS 移植验证")
                        .font(.title2).bold()
                    Text("构建 v8 · 四种后端对比")
                        .font(.caption2)
                        .foregroundColor(.blue)
                }

                if !runner.lastCrashStep.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("上次中断在：\(runner.lastCrashStep)")
                            .font(.footnote)
                            .foregroundColor(.orange)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12))
                    .cornerRadius(10)
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(ComputeMode.allCases, id: \.self) { mode in
                        Button {
                            runner.run(mode: mode)
                        } label: {
                            Text(mode.rawValue)
                                .font(.subheadline).bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(color(for: mode))
                                .foregroundColor(.white)
                                .cornerRadius(20)
                        }
                        .disabled(isBusy)
                    }
                }

                Text(runner.phaseText.isEmpty ? runner.phase.rawValue : runner.phaseText)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(ComputeMode.allCases, id: \.self) { mode in
                    if let summary = runner.summaries[mode] {
                        summaryCard(summary)
                    }
                }

                if !runner.lastNote.isEmpty {
                    Text(runner.lastNote)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("对比要点").font(.footnote).bold()
                    Text("重点看「推理」那一列，和特征余弦是否仍 ≥ 0.999")
                        .font(.caption).foregroundColor(.secondary)
                    Text("XNNPACK 多线程是安卓端在用的组合，理论上最接近")
                        .font(.caption).foregroundColor(.secondary)
                    Text("建 session 只影响启动，不影响每次搜索")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func color(for mode: ComputeMode) -> Color {
        switch mode {
        case .cpu1: return Color(red: 0.95, green: 0.40, blue: 0.13)
        case .cpu4: return Color(red: 0.90, green: 0.55, blue: 0.10)
        case .xnnpack4: return Color(red: 0.20, green: 0.50, blue: 0.75)
        case .coreML: return Color(red: 0.13, green: 0.55, blue: 0.35)
        case .coreMLANE: return Color(red: 0.35, green: 0.35, blue: 0.55)
        }
    }

    @ViewBuilder
    private func summaryCard(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.mode.rawValue)
                    .font(.subheadline).bold()
                    .foregroundColor(color(for: summary.mode))
                Spacer()
                Text(summary.ok ? "完成" : "失败")
                    .font(.caption)
                    .foregroundColor(summary.ok ? .secondary : .red)
            }

            if summary.ok {
                HStack(spacing: 8) {
                    metric("推理", String(format: "%.0f ms", summary.runMs))
                    metric("建 session", String(format: "%.0f ms", summary.sessionMs))
                    metric("特征余弦", String(format: "%.6f", summary.featureCosine))
                }
                Text(summary.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(summary.note.isEmpty ? "失败" : summary.note)
                    .font(.footnote)
                    .foregroundColor(.red)
                Text(summary.detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .bold()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(8)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
