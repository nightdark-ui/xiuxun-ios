import SwiftUI

/// 性能诊断（精简版）：只看/改推理线程数。
/// 其他基准测试已移除，避免误改搜索配置。
struct ProbeView: View {
    @StateObject private var runner = ProbeRunner()
    @State private var manualThreads = DeviceInfo.savedBestThreads
    @State private var currentThreads = DeviceInfo.savedBestThreads

    private var isBusy: Bool { runner.phase == .running }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 设备信息
                VStack(alignment: .leading, spacing: 3) {
                    Text(DeviceInfo.machine)
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(DeviceInfo.coreCount) 核 · \(Int(DeviceInfo.memoryGB.rounded())) GB 内存")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                // 当前生效线程数
                HStack {
                    Text("当前生效线程数")
                        .font(.system(size: 14))
                    Spacer()
                    Text("\(currentThreads)")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundColor(UI.orange)
                }
                .padding(12)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 手动指定
                VStack(alignment: .leading, spacing: 6) {
                    Text("手动指定线程数")
                        .font(.system(size: 13, weight: .semibold))
                    Stepper(value: $manualThreads, in: 1...max(1, DeviceInfo.coreCount)) {
                        Text("\(manualThreads) 线程")
                            .font(.system(size: 14, design: .monospaced))
                    }
                    .disabled(isBusy)

                    HStack(spacing: 8) {
                        Button {
                            DeviceInfo.savedBestThreads = manualThreads
                            currentThreads = manualThreads
                        } label: {
                            Text("保存")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(UI.orange)
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)

                        Button {
                            manualThreads = DeviceInfo.defaultThreads
                            DeviceInfo.savedBestThreads = manualThreads
                            currentThreads = manualThreads
                        } label: {
                            Text("恢复默认 \(DeviceInfo.defaultThreads)")
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Color(.secondarySystemBackground))
                                .foregroundColor(.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }
                .padding(12)
                .background(Color(.secondarySystemBackground).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                // 自动标定
                Button {
                    runner.autotune()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "speedometer")
                        Text(isBusy ? "标定中…" : "自动标定线程数（1…\(DeviceInfo.coreCount)）")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(UI.orange.opacity(0.14))
                    .foregroundColor(UI.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)

                // 标定结果
                if !runner.autotuneRows.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("标定结果（越小越快）")
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(runner.autotuneRows, id: \.threads) { row in
                            HStack {
                                Text("\(row.threads) 线程")
                                    .font(.system(size: 12, design: .monospaced))
                                Spacer()
                                Text(String(format: "%.0f ms", row.ms))
                                    .font(.system(size: 12, design: .monospaced))
                                    .bold()
                            }
                            .foregroundColor(row.threads == currentThreads ? UI.orange : .primary)
                        }
                        if !runner.autotuneBest.isEmpty {
                            Text(runner.autotuneBest)
                                .font(.system(size: 11))
                                .foregroundColor(.green)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                Text("线程数只影响推理速度，不影响搜索结果。更改后下一次搜索生效。")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(14)
        }
    }
}
