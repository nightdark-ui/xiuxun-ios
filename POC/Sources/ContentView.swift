import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("成业绣 DINOv2 数值探针")
                            .font(.title2).bold()
                        Text("验证 ONNX Runtime 在 iOS 上跑 DINOv2-small 的输出是否与 PC/安卓一致。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    Button {
                        runner.run()
                    } label: {
                        HStack {
                            Spacer()
                            Text(runner.phase == .running || runner.phase == .loading ? "正在运行…" : "开始验证")
                                .bold()
                            Spacer()
                        }
                        .padding(.vertical, 14)
                        .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                        .foregroundColor(.white)
                        .cornerRadius(26)
                    }
                    .disabled(runner.phase == .running || runner.phase == .loading)

                    Text(runner.phase.rawValue)
                        .font(.footnote)
                        .foregroundColor(.secondary)

                    if !runner.cosine.isNaN {
                        HStack(spacing: 12) {
                            metric("余弦", String(format: "%.6f", runner.cosine))
                            metric("最大差", String(format: "%.6f", runner.maxAbsDiff))
                            metric("耗时", String(format: "%.0f ms", runner.elapsedMs))
                        }
                    }

                    if !runner.log.isEmpty {
                        Text(runner.log)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .cornerRadius(12)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("判定标准").font(.footnote).bold()
                        Text("余弦 ≥ 0.999：iOS 数值可信，可以继续移植核心算法")
                            .font(.caption).foregroundColor(.secondary)
                        Text("0.99–0.999：多为预处理差异（resize/归一化），仍可修")
                            .font(.caption).foregroundColor(.secondary)
                        Text("< 0.99：先确认模型文件和输入张量是否就是 PC 导出的那份")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationBarHidden(true)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value).font(.system(.footnote, design: .monospaced)).bold()
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
