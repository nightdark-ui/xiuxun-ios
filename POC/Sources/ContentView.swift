import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppState()
    @State private var showProbe = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    galleryCard
                    searchCard
                    probeEntry
                }
                .padding(20)
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showProbe) {
                ProbePanelView()
            }
        }
        .navigationViewStyle(.stack)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("成业绣 AI 搜图")
                .font(.title).bold()
            Text("构建 v1.0 · 图库导入")
                .font(.caption2)
                .foregroundColor(.blue)
            Text(DeviceInfo.summary)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    private var galleryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("图库").font(.headline)
                Spacer()
                if app.hasGallery {
                    Text("\(app.galleryCount) 款").bold().foregroundColor(.green)
                } else {
                    Text("未导入").foregroundColor(.secondary)
                }
            }

            if app.hasGallery {
                ForEach(app.libraries, id: \.name) { item in
                    HStack {
                        Text(item.name).font(.caption)
                        Spacer()
                        Text("\(item.count)").font(.caption).foregroundColor(.secondary)
                    }
                }
                Text(app.galleryPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack(spacing: 10) {
                    Button {
                        app.checkUpdate()
                    } label: {
                        Text("检查更新").font(.footnote).bold()
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Color(red: 0.20, green: 0.50, blue: 0.75))
                            .foregroundColor(.white).cornerRadius(14)
                    }
                    .disabled(app.updating)

                    if app.updateReady {
                        Button {
                            app.applyUpdate()
                        } label: {
                            Text("立即更新").font(.footnote).bold()
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                                .foregroundColor(.white).cornerRadius(14)
                        }
                        .disabled(app.updating)
                    }
                    Spacer()
                }

                if !app.updateSummary.isEmpty {
                    Text(app.updateSummary).font(.caption).foregroundColor(.secondary)
                }

                if app.updating {
                    ProgressView(value: app.progress.fraction)
                    Text("\(app.progress.phase)  \(app.progress.text)")
                        .font(.caption2).foregroundColor(.secondary)
                }

                Button(role: .destructive) {
                    app.clearGallery()
                } label: {
                    Text("删除图库").font(.footnote)
                }
            } else {
                TextField("http://192.168.1.5:8765", text: $app.serverAddress)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .autocapitalization(.none)
                    .disabled(app.installing)

                Text("电脑上运行 serve_gallery.py，把地址填到上面，然后点开始导入。约 4.1GB，需要 5–10 分钟。")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if app.installing {
                    ProgressView(value: app.progress.fraction)
                    Text("\(app.progress.phase)  \(app.progress.text)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button(role: .destructive) {
                        app.cancelInstall()
                    } label: {
                        Text("取消").font(.footnote)
                    }
                } else {
                    Button {
                        app.startInstall()
                    } label: {
                        HStack {
                            Spacer()
                            Text("开始导入").bold()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    }
                }
            }

            if !app.message.isEmpty {
                Text(app.message).font(.caption).foregroundColor(.green)
            }
            if !app.errorText.isEmpty {
                Text(app.errorText).font(.caption).foregroundColor(.red)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("搜索").font(.headline)
            Text(app.hasGallery ? "搜索功能正在开发（下一步接入 DINOv2 召回）" : "先导入图库")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    private var probeEntry: some View {
        Button {
            showProbe = true
        } label: {
            Text("性能诊断（探针）")
                .font(.footnote)
                .foregroundColor(.blue)
        }
    }
}

/// 包住原来的探针界面，方便随时复测
struct ProbePanelView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ProbeView()
                .navigationTitle("性能诊断")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("关闭") { dismiss() }
                    }
                }
        }
    }
}
