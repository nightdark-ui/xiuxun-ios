import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    private var isBusy: Bool { runner.phase == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("成业绣 iOS 移植验证")
                        .font(.title2).bold()
                    Text("A 图像链路（缩放/归一化）+ B 模型数值 + C 推理速度")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // 崩溃断点：如果上次运行中途崩了，这里会显示停在哪一步
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

                // 张量体检：推理前记录的元素数 / NaN / 极值，崩溃后仍可查看
                if !runner.lastNote.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("上次张量体检").font(.caption2).foregroundColor(.secondary)
                        Text(runner.lastNote)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                }

                Button {
                    runner.run()
                } label: {
                    HStack {
                        Spacer()
                        Text(isBusy ? "运行中…" : "开始验证").bold()
                        Spacer()
                    }
                    .padding(.vertical, 14)
                    .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                    .foregroundColor(.white)
                    .cornerRadius(26)
                }
                .disabled(isBusy)

                Text(runner.phase.rawValue)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                if !runner.tensorCosine.isNaN {
                    HStack(spacing: 10) {
                        metric("图像链路余弦", String(format: "%.6f", runner.tensorCosine))
                        metric("最大差", String(format: "%.5f", runner.tensorMaxDiff))
                    }
                    HStack(spacing: 10) {
                        metric("特征余弦", String(format: "%.6f", runner.featureCosine))
                        metric("纯推理", String(format: "%.0f ms", runner.runMs))
                        metric("加载", runner.loadMs > 0 ? String(format: "%.0f ms", runner.loadMs) : "复用")
                    }
                }

                if !runner.log.isEmpty {
                    Text(runner.log)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("判定标准").font(.footnote).bold()
                    Text("图像链路余弦 ≥ 0.9999 → 缩放/归一化与 PC 一致")
                        .font(.caption).foregroundColor(.secondary)
                    Text("特征余弦 ≥ 0.999 → 模型输出一致")
                        .font(.caption).foregroundColor(.secondary)
                    Text("纯推理取三次最快，用来估算整次搜索耗时")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .bold()
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
