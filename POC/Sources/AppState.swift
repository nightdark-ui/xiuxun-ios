import Foundation
import Combine

/// App 全局状态：图库是否就绪、导入进度、错误
final class AppState: ObservableObject {
    @Published var galleryCount: Int = 0
    @Published var libraries: [(name: String, count: Int)] = []
    @Published var installing: Bool = false
    @Published var progress: InstallProgress = InstallProgress()
    @Published var message: String = ""
    @Published var errorText: String = ""

    @Published var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: Self.addressKey) }
    }

    private static let addressKey = "gallery.serverAddress"
    private let installer = GalleryInstaller()
    private var cancelRequested = false
    private(set) var package: GalleryPackage?

    var hasGallery: Bool { package != nil }
    var galleryPath: String { installer.galleryURL.path }

    init() {
        serverAddress = UserDefaults.standard.string(forKey: Self.addressKey) ?? ""
        loadGallery()
    }

    /// 启动时检查沙盒里的图库是否完整
    func loadGallery() {
        guard installer.hasGallery else {
            galleryCount = 0
            libraries = []
            package = nil
            return
        }
        do {
            let opened = try GalleryPackage(root: installer.galleryURL)
            package = opened
            galleryCount = opened.count
            libraries = opened.libraryCounts()
            message = "图库已就绪"
        } catch {
            package = nil
            galleryCount = 0
            libraries = []
            errorText = "图库读取失败：\(error.localizedDescription)"
        }
    }

    func startInstall() {
        guard !installing else { return }
        let address = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else {
            errorText = "请先填写电脑上的地址，例如 http://192.168.1.5:8765"
            return
        }
        installing = true
        cancelRequested = false
        errorText = ""
        message = ""
        progress = InstallProgress(phase: "准备中…")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                try self.installer.install(
                    baseURL: address,
                    progress: { value in
                        DispatchQueue.main.async { self.progress = value }
                    },
                    isCancelled: { self.cancelRequested }
                )
                DispatchQueue.main.async {
                    self.installing = false
                    self.loadGallery()
                    self.message = "图库导入完成：\(self.galleryCount) 款"
                }
            } catch {
                DispatchQueue.main.async {
                    self.installing = false
                    if case InstallError.cancelled = error {
                        self.message = "已取消，已下载的部分会保留，下次继续"
                    } else {
                        self.errorText = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelInstall() {
        cancelRequested = true
    }

    func clearGallery() {
        try? installer.removeGallery()
        loadGallery()
        message = "图库已删除"
    }
}
