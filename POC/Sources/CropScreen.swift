import SwiftUI

/// 框选搜索：拖动/缩放一个矩形，只搜框内区域。
struct CropScreen: View {
    let image: UIImage
    let onConfirm: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    /// 归一化坐标（0…1）
    @State private var rect = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
    @State private var dragStart: CGRect?

    var body: some View {
        NavigationView {
            GeometryReader { geo in
                let fitted = fittedFrame(image: image, in: geo.size)
                ZStack {
                    Color.black
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)

                    // 框选区域
                    let box = CGRect(
                        x: fitted.minX + rect.minX * fitted.width,
                        y: fitted.minY + rect.minY * fitted.height,
                        width: rect.width * fitted.width,
                        height: rect.height * fitted.height
                    )

                    Rectangle()
                        .fill(Color.black.opacity(0.45))
                        .mask(
                            ZStack {
                                Rectangle().fill(Color.white)
                                Rectangle()
                                    .frame(width: box.width, height: box.height)
                                    .position(x: box.midX, y: box.midY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        )

                    Rectangle()
                        .stroke(Color.orange, lineWidth: 2)
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)

                    // 右下角缩放柄
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 26, height: 26)
                        .position(x: box.maxX, y: box.maxY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = dragStart ?? rect
                                    if dragStart == nil { dragStart = start }
                                    var next = start
                                    next.size.width = clamp(start.width + value.translation.width / fitted.width, 0.05, 1 - start.minX)
                                    next.size.height = clamp(start.height + value.translation.height / fitted.height, 0.05, 1 - start.minY)
                                    rect = next
                                }
                                .onEnded { _ in dragStart = nil }
                        )

                    // 内部拖动（整体移动）
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let start = dragStart ?? rect
                                    if dragStart == nil { dragStart = start }
                                    var next = start
                                    next.origin.x = clamp(start.minX + value.translation.width / fitted.width, 0, 1 - start.width)
                                    next.origin.y = clamp(start.minY + value.translation.height / fitted.height, 0, 1 - start.height)
                                    rect = next
                                }
                                .onEnded { _ in dragStart = nil }
                        )
                }
            }
            .ignoresSafeArea()
            .navigationTitle("拖动框选要搜的区域")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("整图搜索") {
                        onConfirm(image)
                        dismiss()
                    }
                    Spacer()
                    Button {
                        if let cropped = crop(image: image, rect: rect) {
                            onConfirm(cropped)
                        }
                        dismiss()
                    } label: {
                        Text("搜框内").bold()
                    }
                }
            }
        }
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), max(low, high))
    }

    private func fittedFrame(image: UIImage, in size: CGSize) -> CGRect {
        let imageRatio = image.size.width / max(1, image.size.height)
        let viewRatio = size.width / max(1, size.height)
        if imageRatio > viewRatio {
            let height = size.width / imageRatio
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        }
        let width = size.height * imageRatio
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func crop(image: UIImage, rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        let target = CGRect(
            x: rect.minX * width,
            y: rect.minY * height,
            width: max(16, rect.width * width),
            height: max(16, rect.height * height)
        )
        guard let cropped = cgImage.cropping(to: target) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
    }
}
