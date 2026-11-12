import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppState()
    @State private var showProbe = false
    @State private var showSplash = true

    var body: some View {
        ZStack {
            TabView {
            NavigationView {
                VStack(spacing: 8) {
                    if app.hasGallery {
                        SearchView(app: app)
                    } else {
                        Spacer()
                        Text("请先在「图库」里导入图库")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                }
                .navigationTitle("搜索")
                .navigationBarTitleDisplayMode(.inline)
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("搜图", systemImage: "magnifyingglass") }
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        galleryCard
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
            .tabItem { Label("图库", systemImage: "square.grid.2x2") }
            NavigationView {
                SettingsView()
            }
            .navigationViewStyle(.stack)
            .tabItem { Label("设置", systemImage: "gearshape") }
            }

            if showSplash {
                SplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeInOut(duration: 0.3)) { showSplash = false }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PicSeek")
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

                Divider()

                Text("图库位置（可在「文件」App 里直接替换）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("我的 iPhone / PicSeek / Gallery")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.blue)

                NavigationLink {
                    GalleryBrowser(app: app)
                } label: {
                    Text("浏览图库")
                        .font(.footnote).bold()
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(UI.orange)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }

                HStack(spacing: 10) {
                    Button {
                        app.verifyGallery()
                    } label: {
                        Text(app.verifying ? "校验中…" : "校验图库")
                            .font(.footnote).bold()
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(UI.orange.opacity(0.12))
                            .foregroundColor(UI.orange)
                            .clipShape(Capsule())
                    }
                    .disabled(app.verifying)

                    Button(role: .destructive) {
                        app.clearGallery()
                    } label: {
                        Text("删除图库").font(.footnote)
                    }
                    Spacer()
                }

                if !app.verifyText.isEmpty {
                    Text(app.verifyText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(UI.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有图库").font(.subheadline).bold()
                    Text("把图库文件夹（含 index.json、recall.bin、heavy.bin、images、thumbs、models）拷到：")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("我的 iPhone / PicSeek / Gallery")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.blue)
                    Text("用 iTunes 文件共享、iCloud 或「文件」App 都可以。拷完回到这里会自动识别。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button {
                    app.loadGallery()
                } label: {
                    HStack {
                        Spacer()
                        Text("重新检测图库").bold()
                        Spacer()
                    }
                    .padding(.vertical, 12)
                    .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                    .foregroundColor(.white)
                    .cornerRadius(20)
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
