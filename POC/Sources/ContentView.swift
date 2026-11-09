import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    private var isBusy: Bool { runner.phase == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("成业绣 iOS 移植验证")
                        .font(.title2).bold()
                    Text("构建 v7 · CPU 与 CoreML 对比")
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

                HStack(spacing: 10) {
                    Button {
                        runner.run(mode: .cpu)
                    } label: {
                        HStack {
                            Spacer()
                            Text("CPU 测试").bold()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                        .foregroundColor(.white)
                        .cornerRadius(22)
                    }
                    .disabled(isBusy)

                    Button {
                        runner.run(mode: .coreML)
                    } label: {
                        HStack {
                            Spacer()
                            Text("CoreML 测试").bold()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(Color(red: 0.13, green: 0.55, blue: 0.35))
                        .foregroundColor(.white)
                        .cornerRadius(22)
                    }
                    .disabled(isBusy)
                }

                Text(runner.phaseText.isEmpty ? runner.phase.rawValue : runner.phaseText)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if let cpu = runner.cpuSummary {
                    summaryCard(cpu, accent: .orange)
                }
                if let coreML = runner.coreMLSummary {
                    summaryCard(coreML, accent: .green)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("怎么读").font(.footnote).bold()
                    Text("先点 CPU 测试，再点 CoreML 测试，两边数字直接对比")
                        .font(.caption).foregroundColor(.secondary)
                    Text("「推理」是纯推理耗时；「建 session」包含 CoreML 首次编译，通常更慢")
                        .font(.caption).foregroundColor(.secondary)
                    Text("CoreML 的特征余弦若低于 0.999，说明数值漂移，不能直接用于搜索")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func summaryCard(_ summary: RunSummary, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.mode.rawValue)
                    .font(.subheadline).bold()
                    .foregroundColor(accent)
                Spacer()
                Text(summary.ok ? "完成" : "失败")
                    .font(.caption)
                    .foregroundColor(summary.ok ? .secondary : .red)
            }

            if summary.ok {
                HStack(spacing: 8) {
                    metric("特征余弦", String(format: "%.6f", summary.featureCosine))
                    metric("推理", String(format: "%.0f ms", summary.runMs))
                    metric("建 session", String(format: "%.0f ms", summary.sessionMs))
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
