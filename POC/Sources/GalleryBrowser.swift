import SwiftUI

/// 图库浏览：按库切换、按编号搜索、网格浏览。
struct GalleryBrowser: View {
    @ObservedObject var app: AppState

    @State private var selectedLibrary: String = ""   // 空 = 全部
    @State private var keyword: String = ""
    @State private var selected: DesignRef?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 240), spacing: 8)]
    }

    private var designs: [DesignRef] {
        guard let package = app.package else { return [] }
        var list = package.designs
        if !selectedLibrary.isEmpty {
            list = list.filter { $0.library == selectedLibrary }
        }
        // 按编号自然排序（TM 条码等库的 index 顺序是乱的）
        list.sort { $0.code.localizedStandardCompare($1.code) == .orderedAscending }

        let key = keyword.trimmingCharacters(in: .whitespaces).uppercased()
        if !key.isEmpty {
            list = list.filter {
                $0.code.uppercased().contains(key) || $0.title.uppercased().contains(key)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 8) {
            libraryBar
            searchBar
            Text("\(designs.count) 款")
                .font(.system(size: 11))
                .foregroundColor(UI.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(designs.prefix(600), id: \.index) { design in
                        Button {
                            selected = design
                        } label: {
                            VStack(spacing: 3) {
                                CachedThumb(
                                    url: app.package?.thumbURL(for: design),
                                    height: 96
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(design.code.isEmpty ? design.title : design.code)
                                    .font(.system(size: 9))
                                    .foregroundColor(UI.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
        }
        .background(UI.pageBackground.ignoresSafeArea())
        .navigationTitle("浏览图库")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )) {
            if let design = selected, let package = app.package {
                DesignViewer(design: design, package: package)
            }
        }
    }

    private var libraryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                libraryChip("全部", active: selectedLibrary.isEmpty) {
                    selectedLibrary = ""
                }
                ForEach(app.libraries, id: \.name) { item in
                    libraryChip("\(item.name)（\(item.count)）", active: selectedLibrary == item.name) {
                        selectedLibrary = item.name
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func libraryChip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(active ? UI.orange : UI.cardBackground)
                .foregroundColor(active ? .white : UI.textPrimary)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(UI.divider, lineWidth: 0.6))
        }
        .buttonStyle(.plain)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(UI.textSecondary)
            TextField("按编号搜索，如 SL9015", text: $keyword)
                .font(.system(size: 13))
                .disableAutocorrection(true)
                .autocapitalization(.allCharacters)
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(UI.textSecondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(UI.cardBackground)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(UI.divider, lineWidth: 0.6))
        .padding(.horizontal, 12)
    }
}

/// 单款大图查看
struct DesignViewer: View {
    let design: DesignRef
    let package: GalleryPackage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    // 一款多图：主图 + 补充图，可横向翻页
                    let urls = package.imageURLs(for: design)
                    TabView {
                        ForEach(Array(urls.enumerated()), id: \.offset) { offset, url in
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    CachedThumb(url: package.thumbURL(for: design), height: 260)
                                }
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .always : .never))
                    .frame(height: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    if urls.count > 1 {
                        Text("共 \(urls.count) 张（主图 + 补充 \(urls.count - 1)）")
                            .font(.system(size: 11))
                            .foregroundColor(UI.textSecondary)
                    }

                    Text(design.code.isEmpty ? design.title : design.code)
                        .font(.system(size: 20, weight: .bold))
                    Text(design.library)
                        .font(.system(size: 12))
                        .foregroundColor(UI.textSecondary)
                    Text("款 ID：\(design.id)    特征：\(design.featureUUID.prefix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(UI.textSecondary)
                }
                .padding(16)
            }
            .background(UI.pageBackground.ignoresSafeArea())
            .navigationTitle("花型详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
