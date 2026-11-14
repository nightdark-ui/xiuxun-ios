import AVFoundation
import SwiftUI

/// 自建相机（安全版：权限检查 + 同步配置 + 无强制解包）
struct CameraView: View {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = CameraModel()
    @State private var denied = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if denied {
                VStack(spacing: 12) {
                    Image(systemName: "camera.fill").font(.system(size: 38)).foregroundColor(.white.opacity(0.7))
                    Text("没有相机权限").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    Text("请到 设置 → 隐私与安全性 → 相机 里允许 PicSeek 使用相机")
                        .font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 30)
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .background(UI.orange).foregroundColor(.white)
                    .clipShape(Capsule())
                }
            } else {
                CameraPreview(session: model.session)
                    .ignoresSafeArea()

                VStack {
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { model.toggleTorch() } label: {
                            Image(systemName: model.torchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(model.torchOn ? UI.orange : .white)
                                .frame(width: 40, height: 40)
                                .background(Color.black.opacity(0.45))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)

                    Spacer()

                    HStack(spacing: 16) {
                        ForEach(model.zoomOptions, id: \.self) { factor in
                            Button { model.setZoom(factor) } label: {
                                Text(model.zoomLabel(factor))
                                    .font(.system(size: model.zoom == factor ? 13 : 12,
                                                  weight: model.zoom == factor ? .bold : .regular))
                                    .foregroundColor(model.zoom == factor ? UI.orange : .white.opacity(0.85))
                                    .frame(width: 34, height: 34)
                                    .background(model.zoom == factor ? Color.white : Color.clear)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 16)

                    HStack {
                        Button { model.openLibrary() } label: {
                            Image(systemName: "photo.on.rectangle")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 46, height: 46)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            model.pending = { image in
                                if let image {
                                    onCapture(image)
                                    dismiss()
                                }
                            }
                            model.capture()
                        } label: {
                            ZStack {
                                Circle().fill(Color.white).frame(width: 72, height: 72)
                                Circle().stroke(Color.white.opacity(0.45), lineWidth: 4).frame(width: 84, height: 84)
                                if model.busy { ProgressView().tint(.black) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy)

                        Spacer()

                        Button { model.flip() } label: {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                                .font(.system(size: 20))
                                .foregroundColor(.white)
                                .frame(width: 46, height: 46)
                                .background(Color.white.opacity(0.16))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 26)
                    .padding(.bottom, 26)
                }
            }

            if let message = model.errorText {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { prepare() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $model.showLibrary) {
            ImagePicker(sourceType: .photoLibrary) { image in
                model.showLibrary = false
                onCapture(image)
                dismiss()
            }
        }
    }

    private func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            model.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { model.start() } else { denied = true }
                }
            }
        default:
            denied = true
        }
    }
}

/// 预览层（安全类型转换）
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        if let layer = view.layer as? AVCaptureVideoPreviewLayer {
            layer.session = session
            layer.videoGravity = .resizeAspectFill
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    }
}

/// 相机逻辑
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published var zoom: CGFloat = 1
    @Published var torchOn = false
    @Published var busy = false
    @Published var errorText: String?
    @Published var showLibrary = false

    let zoomOptions: [CGFloat] = [1, 2, 4]

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private var device: AVCaptureDevice?
    private var configured = false
    private var useFront = false
    var pending: ((UIImage?) -> Void)?

    func start() {
        guard !configured else {
            queue.async { if !self.session.isRunning { self.session.startRunning() } }
            return
        }
        configured = true
        queue.async {
            self.configure()
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: useFront ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorText = "无法打开相机" }
            return
        }
        session.addInput(input)
        device = camera

        if session.canAddOutput(output) {
            session.addOutput(output)
        }
    }

    private func rebuildInput() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                position: useFront ? .front : .back),
           let input = try? AVCaptureDeviceInput(device: camera),
           session.canAddInput(input) {
            session.addInput(input)
            device = camera
        }
        session.commitConfiguration()
    }

    func flip() {
        useFront.toggle()
        queue.async { self.rebuildInput() }
    }

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = torchOn ? .off : .on
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn.toggle() }
        } catch {
            DispatchQueue.main.async { self.errorText = "闪光灯不可用" }
        }
    }

    func setZoom(_ factor: CGFloat) {
        zoom = factor
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            let maxZoom = min(factor, device.activeFormat.videoMaxZoomFactor)
            device.videoZoomFactor = max(1, maxZoom)
            device.unlockForConfiguration()
        } catch {}
    }

    func zoomLabel(_ factor: CGFloat) -> String {
        factor == 1 ? "1×" : "\(Int(factor))×"
    }

    func openLibrary() {
        stop()
        showLibrary = true
    }

    func capture() {
        guard !busy else { return }
        busy = true
        let settings = AVCapturePhotoSettings()
        if let device, device.hasTorch, torchOn {
            settings.flashMode = .on
        }
        queue.async {
            guard self.session.isRunning, !self.output.connections.isEmpty else {
                DispatchQueue.main.async {
                    self.busy = false
                    self.errorText = "相机未就绪，请稍后再试"
                }
                return
            }
            self.output.capturePhoto(with: settings, delegate: self)
        }
    }

    private func finish(_ image: UIImage?) {
        DispatchQueue.main.async {
            self.busy = false
            self.pending?(image)
            self.pending = nil
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            finish(nil)
            return
        }
        finish(image)
    }
}
