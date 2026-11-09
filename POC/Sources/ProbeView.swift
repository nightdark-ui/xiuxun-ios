import SwiftUI

/// 性能诊断面板（原探针界面，用于复测线程数、批处理、各后端速度）
struct ProbeView: View {
    @StateObject private var runner = ProbeRunner()

    private var isBusy: Bool { runner.phase == .running }
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(DeviceInfo.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if !runner.lastCrashStep.isEmpty && runner.lastCrashStep != "完成" {
                    Text("上次中断在：\(runner.lastCrashStep)")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(ComputeMode.allCases, id: \.self) { mode in
                        Button {
                            runner.run(mode: mode)
                        } label: {
                            Text(mode.rawValue)
                                .font(.caption).bold()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(color(for: mode))
                                .foregroundColor(.white)
                                .cornerRadius(16)
                        }
                        .disabled(isBusy)
                    }
                }

                Button {
                    runner.autotune()
                } label: {
                    fullWidthLabel("自动标定线程数（1…\(DeviceInfo.coreCount)）", color: Color(red: 0.35, green: 0.35, blue: 0.55))
                }
                .disabled(isBusy)

                if !runner.autotuneRows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("线程标定").font(.subheadline).bold()
                        ForEach(runner.autotuneRows, id: \.threads) { row in
                            HStack {
                                Text("\(row.threads) 线程").font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(String(format: "%.0f ms", row.ms))
                                    .font(.system(size: 12, design: .monospaced)).bold()
                            }
                        }
                        if !runner.autotuneBest.isEmpty {
                            Text(runner.autotuneBest).font(.caption).foregroundColor(.green)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                }

                Button {
                    runner.batchTest()
                } label: {
                    fullWidthLabel("批处理测试（1/4/10/20）", color: Color(red: 0.15, green: 0.45, blue: 0.50))
                }
                .disabled(isBusy)

                if !runner.batchRows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("批处理").font(.subheadline).bold()
                        ForEach(runner.batchRows, id: \.size) { row in
                            HStack {
                                Text("批 \(row.size)").font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(String(format: "总 %.0f ms", row.ms))
                                    .font(.system(size: 12, design: .monospaced))
                                Text(String(format: "每张 %.0f ms", row.perImage))
                                    .font(.system(size: 12, design: .monospaced)).bold()
                                    .foregroundColor(.blue)
                            }
                        }
                        if !runner.batchBest.isEmpty {
                            Text(runner.batchBest).font(.caption).foregroundColor(.green)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                }

                Text(runner.phaseText.isEmpty ? runner.phase.rawValue : runner.phaseText)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                ForEach(ComputeMode.allCases, id: \.self) { mode in
                    if let summary = runner.summaries[mode] {
                        summaryCard(summary)
                    }
                }
            }
            .padding(16)
        }
    }

    private func fullWidthLabel(_ text: String, color: Color) -> some View {
        HStack {
            Spacer()
            Text(text).font(.footnote).bold()
            Spacer()
        }
        .padding(.vertical, 10)
        .background(color)
        .foregroundColor(.white)
        .cornerRadius(16)
    }

    private func color(for mode: ComputeMode) -> Color {
        switch mode {
        case .cpu1: return Color(red: 0.95, green: 0.40, blue: 0.13)
        case .cpu4: return Color(red: 0.90, green: 0.55, blue: 0.10)
        case .cpuAll: return Color(red: 0.85, green: 0.35, blue: 0.20)
        case .xnnpackAll: return Color(red: 0.20, green: 0.50, blue: 0.75)
        case .coreML: return Color(red: 0.13, green: 0.55, blue: 0.35)
        case .coreMLANE: return Color(red: 0.35, green: 0.35, blue: 0.55)
        }
    }

    @ViewBuilder
    private func summaryCard(_ summary: RunSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.mode.rawValue).font(.caption).bold()
                    .foregroundColor(color(for: summary.mode))
                Spacer()
                Text(summary.ok ? "完成" : "失败").font(.caption2).foregroundColor(.secondary)
            }
            if summary.ok {
                HStack(spacing: 6) {
                    metric("推理", String(format: "%.0f ms", summary.runMs))
                    metric("建 session", String(format: "%.0f ms", summary.sessionMs))
                    metric("余弦", String(format: "%.6f", summary.featureCosine))
                }
                Text(summary.detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text(summary.note).font(.caption2).foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced)).bold()
                .minimumScaleFactor(0.5).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemBackground))
        .cornerRadius(6)
    }
}
