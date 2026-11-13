import AVFoundation
import SwiftUI

/// 自建相机（对齐 App 橙色风格：上方关闭/闪光，下方相册/快门/翻转）
struct CameraView: View {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = CameraModel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: model.session)
                .ignoresSafeArea()

            VStack {
                // ---------- 上方 ----------
                HStack {
                    Button {
                        model.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        model.toggleTorch()
                    } label: {
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

                // 缩放档位
                HStack(spacing: 16) {
                    ForEach(model.zoomOptions, id: \.self) { factor in
                        Button {
                            model.setZoom(factor)
                        } label: {
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

                // ---------- 下方 ----------
                HStack {
                    // 相册
                    Button {
                        model.openLibrary()
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    // 快门
                    Button {
                        model.capture { image in
                            if let image {
                                onCapture(image)
                                dismiss()
                            }
                        }
                    } label: {
                        ZStack {
                            Circle().fill(Color.white).frame(width: 72, height: 72)
                            Circle().stroke(Color.white.opacity(0.45), lineWidth: 4)
                                .frame(width: 84, height: 84)
                            if model.busy {
                                ProgressView().tint(.black)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)

                    Spacer()

                    // 翻转
                    Button {
                        model.flip()
                    } label: {
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

            if let message = model.errorText {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .sheet(isPresented: $model.showLibrary) {
            ImagePicker(sourceType: .photoLibrary) { image in
                model.showLibrary = false
                onCapture(image)
                dismiss()
            }
        }
    }
}

/// 相机预览层
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// 相机逻辑
final class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var zoom: CGFloat = 1
    @Published var torchOn = false
    @Published var busy = false
    @Published var errorText: String?
    @Published var showLibrary = false

    let zoomOptions: [CGFloat] = [1, 2, 4]

    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var configured = false
    private var useFront = false
    private var handler: ((UIImage?) -> Void)?

    func start() {
        guard !configured else {
            if !session.isRunning { DispatchQueue.global().async { self.session.startRunning() } }
            return
        }
        configured = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.configure()
            self.session.startRunning()
        }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        if torchOn { toggleTorch() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        defer { session.commitConfiguration() }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: useFront ? .front : .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorText = "无法打开相机" }
            return
        }
        session.addInput(input)
        self.device = device

        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
    }

    private func rebuildInput() {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                position: useFront ? .front : .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            self.device = device
        }
        session.commitConfiguration()
    }

    func flip() {
        useFront.toggle()
        DispatchQueue.global().async { self.rebuildInput() }
    }

    func toggleTorch() {
        guard let device, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = torchOn ? .off : .on
        device.unlockForConfiguration()
        torchOn.toggle()
    }

    func setZoom(_ factor: CGFloat) {
        zoom = factor
        guard let device else { return }
        try? device.lockForConfiguration()
        device.videoZoomFactor = max(1, min(factor, device.activeFormat.videoMaxZoomFactor))
        device.unlockForConfiguration()
    }

    func zoomLabel(_ factor: CGFloat) -> String {
        factor == 1 ? "1×" : "\(Int(factor))×"
    }

    func openLibrary() {
        stop()
        showLibrary = true
    }

    func capture(completion: @escaping (UIImage?) -> Void) {
        guard !busy else { return }
        busy = true
        handler = completion
        let settings = AVCapturePhotoSettings()
        if let device, device.hasTorch, torchOn {
            settings.flashMode = .on
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_ output: AVCaptureOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        busy = false
        guard error == nil, let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            handler?(nil)
            return
        }
        handler?(image)
    }
}
