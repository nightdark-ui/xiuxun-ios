import SwiftUI
import UIKit

/// 系统相册/相机选择器
struct ImagePicker: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .photoLibrary
    var onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = sourceType
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: ImagePicker
        init(_ parent: ImagePicker) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onPick(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

/// 搜索状态
final class SearchModel: ObservableObject {
    @Published var busy = false
    @Published var progressText = ""
    @Published var hits: [SearchHit] = []
    @Published var timings: SearchTimings?
    @Published var note = ""
    @Published var errorText = ""
    @Published var previewImage: UIImage?
    @Published var queryThumb: UIImage?
    @Published var elapsedText: String = ""

    var options: SearchOptions { AppSettings.shared.makeOptions() }

    private var encoder: QueryEncoder?
    private var search: GallerySearch?
    private var packageIdentity: Int = 0

    func prepare(package: GalleryPackage) {
        if search == nil || packageIdentity != package.count {
            search = GallerySearch(package: package)
            packageIdentity = package.count
        }
    }

    func run(image: UIImage, package: GalleryPackage) {
        guard !busy else { return }
        busy = true
        errorText = ""
        hits = []
        timings = nil
        note = ""
        progressText = "准备中…"
        queryThumb = image
        prepare(package: package)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let started = Date()

                // 写入临时文件（复用同一套解码/增强流程）
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("query-\(UUID().uuidString).jpg")
                guard let data = image.jpegData(compressionQuality: 0.95) else {
                    throw InstallError.verify("图片编码失败")
                }
                try data.write(to: tempURL)
                defer { try? FileManager.default.removeItem(at: tempURL) }

                self.update("预处理…")
                let enhanced = try ImageOps.loadEnhancedGray(from: tempURL)

                let encoder = try self.getEncoder()
                guard let search = self.search else {
                    throw InstallError.verify("搜索器未就绪")
                }
                let outcome = try search.search(
                    enhancedGray: enhanced,
                    options: self.options,
                    encoder: encoder,
                    progress: { text in self.update(text) }
                )

                DispatchQueue.main.async {
                    self.hits = outcome.hits
                    self.timings = outcome.timings
                    self.note = outcome.note
                    self.busy = false
                    self.progressText = ""
                    self.elapsedText = String(format: "%.1f 秒", outcome.timings.totalMs / 1000)
                    self.queryThumb = image
                }
                _ = started
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.progressText = ""
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    private func update(_ text: String) {
        DispatchQueue.main.async { self.progressText = text }
    }

    private func getEncoder() throws -> QueryEncoder {
        if let encoder = encoder { return encoder }
        let threads = DeviceInfo.savedBestThreads
        let created = try QueryEncoder(threads: threads)
        encoder = created
        return created
    }
}

/// 搜索界面
struct SearchView: View {
    @ObservedObject var app: AppState
    @StateObject private var model = SearchModel()
    @State private var showPicker = false
    @State private var showCamera = false
    @State private var detail: SearchHit?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button {
                    showPicker = true
                } label: {
                    actionLabel("选择图片", color: Color(red: 0.95, green: 0.40, blue: 0.13))
                }
                Button {
                    showCamera = true
                } label: {
                    actionLabel("拍照", color: Color(red: 0.20, green: 0.50, blue: 0.75))
                }
            }
            .disabled(model.busy)

            if model.busy {
                ProgressView()
                Text(model.progressText).font(.caption).foregroundColor(.secondary)
            }

            if !model.errorText.isEmpty {
                Text(model.errorText).font(.caption).foregroundColor(.red)
            }

            if let timings = model.timings {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timings.text)
                        .font(.system(size: 10, design: .monospaced))
                    if !model.note.isEmpty {
                        Text(model.note).font(.caption2).foregroundColor(.green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
            }

            if model.hits.isEmpty {
                Spacer()
                Text(app.hasGallery ? "选择或拍摄一张花型图开始搜索" : "请先导入图库")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(model.hits.enumerated()), id: \.offset) { index, hit in
                            Button {
                                detail = hit
                            } label: {
                                resultCell(hit: hit, rank: index + 1)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .sheet(isPresented: $showPicker) {
            ImagePicker(sourceType: .photoLibrary) { image in
                if let package = app.package {
                    model.run(image: image, package: package)
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            ImagePicker(sourceType: .camera) { image in
                if let package = app.package {
                    model.run(image: image, package: package)
                }
            }
        }
        .sheet(item: $detail) { hit in
            ResultDetail(hit: hit, package: app.package)
        }
    }

    private func actionLabel(_ text: String, color: Color) -> some View {
        Text(text).bold()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(18)
    }

    private func resultCell(hit: SearchHit, rank: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if let package = app.package {
                    AsyncImage(url: package.thumbURL(for: hit.design)) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color(.secondarySystemBackground)
                        }
                    }
                    .frame(height: 120)
                    .clipped()
                    .cornerRadius(10)
                }
                Text("\(rank)")
                    .font(.caption2).bold()
                    .padding(4)
                    .background(Color.black.opacity(0.55))
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .padding(4)
            }
            Text(hit.design.code.isEmpty ? hit.design.title : hit.design.code)
                .font(.caption).bold()
                .lineLimit(1)
            Text(String(format: "%.1f", hit.score * 100))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

extension SearchHit: Identifiable {
    var id: Int { design.index }
}

/// 结果详情
struct ResultDetail: View {
    let hit: SearchHit
    let package: GalleryPackage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let package = package {
                        AsyncImage(url: package.imageURL(for: hit.design)) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                ProgressView().frame(height: 220)
                            }
                        }
                    }
                    Text(hit.design.code).font(.title3).bold()
                    Text(hit.design.library).font(.caption).foregroundColor(.secondary)
                    Group {
                        row("综合分", String(format: "%.1f", hit.score * 100))
                        row("CLS", String(format: "%.3f", hit.clsScore))
                        row("tile", String(format: "%.3f", hit.tileScore))
                        row("base", String(format: "%.3f", hit.baseScore))
                    }
                }
                .padding(16)
            }
            .navigationTitle("详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.footnote).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.system(.footnote, design: .monospaced)).bold()
        }
    }
}
