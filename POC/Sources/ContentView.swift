import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    private var isBusy: Bool { runner.phase == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("成业绣 DINOv2 数值探针")
                        .font(.title2).bold()
                    Text("验证 ONNX Runtime 在 iOS 上跑 DINOv2-small 的数值与速度。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Button {
                    runner.run()
                } label: {
                    HStack {
                        Spacer()
                        Text(isBusy ? "正在运行…" : "开始验证").bold()
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

                if !runner.cosine.isNaN {
                    HStack(spacing: 10) {
                        metric("余弦", String(format: "%.6f", runner.cosine))
                        metric("最大差", String(format: "%.6f", runner.maxAbsDiff))
                        metric(
                            "纯推理",
                            runner.runMs.isEmpty
                                ? "-"
                                : String(format: "%.0f ms", runner.runMs.min() ?? 0)
                        )
                    }
                    HStack(spacing: 10) {
                        metric("加载", runner.loadMs > 0 ? String(format: "%.0f ms", runner.loadMs) : "复用")
                        metric(
                            "三次推理",
                            runner.runMs.map { String(format: "%.0f", $0) }.joined(separator: " / ")
                        )
                    }
                }

                if !runner.message.isEmpty {
                    Text(runner.message)
                        .font(.system(.footnote, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("怎么读这组数").font(.footnote).bold()
                    Text("余弦 ≥ 0.999 → 数值与 PC/安卓一致")
                        .font(.caption).foregroundColor(.secondary)
                    Text("“纯推理”取三次里最快的一次，代表这台 iPhone 跑一次 224 前向的真实耗时")
                        .font(.caption).foregroundColor(.secondary)
                    Text("点第二次按钮时“加载”会显示复用，说明模型没有重复加载")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2).foregroundColor(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .bold()
                .minimumScaleFactor(0.6)
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
