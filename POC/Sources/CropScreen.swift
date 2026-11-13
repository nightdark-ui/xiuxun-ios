import SwiftUI

/// 框选搜索：四角可缩放 + 内部可拖动，只搜框内区域。
struct CropScreen: View {
    let image: UIImage
    /// didCrop == false 表示用户没有动过框（用整图）
    let onConfirm: (UIImage, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rect = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.84)
    @State private var startRect: CGRect?
    @State private var touched = false

    private var didCrop: Bool {
        touched && (rect.width < 0.97 || rect.height < 0.97 || rect.minX > 0.015 || rect.minY > 0.015)
    }

    var body: some View {
        GeometryReader { geo in
            let fitted = fittedFrame(image: image, in: geo.size)
            let box = CGRect(
                x: fitted.minX + rect.minX * fitted.width,
                y: fitted.minY + rect.minY * fitted.height,
                width: rect.width * fitted.width,
                height: rect.height * fitted.height
            )

            ZStack {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)

                // 框外遮罩
                Rectangle()
                    .fill(Color.black.opacity(0.5))
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
                    .allowsHitTesting(false)

                // 框线
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.95), lineWidth: 1.5)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)

                // 内部拖动
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: max(0, box.width - 48), height: max(0, box.height - 48))
                    .position(x: box.midX, y: box.midY)
                    .gesture(moveGesture(fitted: fitted))

                // 四角手柄
                cornerHandle(at: CGPoint(x: box.minX, y: box.minY), fitted: fitted, corner: .topLeft)
                cornerHandle(at: CGPoint(x: box.maxX, y: box.minY), fitted: fitted, corner: .topRight)
                cornerHandle(at: CGPoint(x: box.minX, y: box.maxY), fitted: fitted, corner: .bottomLeft)
                cornerHandle(at: CGPoint(x: box.maxX, y: box.maxY), fitted: fitted, corner: .bottomRight)

                // 顶部提示
                VStack {
                    Text("拖动四角缩放，拖动框内移动")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.45))
                        .clipShape(Capsule())
                        .padding(.top, 8)
                    Spacer()
                }

                // 底部操作栏
                VStack {
                    Spacer()
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                        } label: {
                            Text("取消")
                                .font(.system(size: 15, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.white.opacity(0.14))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            onConfirm(image, false)
                            dismiss()
                        } label: {
                            Text("整图搜索")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color.white)
                                .foregroundColor(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        Button {
                            if let cropped = crop(image: image, rect: rect) {
                                onConfirm(cropped, true)
                            }
                            dismiss()
                        } label: {
                            Text("搜框内")
                                .font(.system(size: 15, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Color(red: 0.95, green: 0.40, blue: 0.13))
                                .foregroundColor(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 26)
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 手势

    private enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    private func cornerHandle(at point: CGPoint, fitted: CGRect, corner: Corner) -> some View {
        Circle()
            .fill(Color.white)
            .overlay(Circle().stroke(Color(red: 0.95, green: 0.40, blue: 0.13), lineWidth: 3))
            .frame(width: 30, height: 30)
            .position(point)
            .gesture(resizeGesture(fitted: fitted, corner: corner))
    }

    private func resizeGesture(fitted: CGRect, corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startRect == nil { startRect = rect; touched = true }
                let dx = value.translation.width / fitted.width
                let dy = value.translation.height / fitted.height
                guard let base = startRect else { return }
                var next = base
                switch corner {
                case .topLeft:
                    let newX = clamp(base.minX + dx, 0, base.maxX - 0.08)
                    let newY = clamp(base.minY + dy, 0, base.maxY - 0.08)
                    next = CGRect(x: newX, y: newY,
                                  width: base.maxX - newX, height: base.maxY - newY)
                case .topRight:
                    let newMaxX = clamp(base.maxX + dx, base.minX + 0.08, 1)
                    let newY = clamp(base.minY + dy, 0, base.maxY - 0.08)
                    next = CGRect(x: base.minX, y: newY,
                                  width: newMaxX - base.minX, height: base.maxY - newY)
                case .bottomLeft:
                    let newX = clamp(base.minX + dx, 0, base.maxX - 0.08)
                    let newMaxY = clamp(base.maxY + dy, base.minY + 0.08, 1)
                    next = CGRect(x: newX, y: base.minY,
                                  width: base.maxX - newX, height: newMaxY - base.minY)
                case .bottomRight:
                    let newMaxX = clamp(base.maxX + dx, base.minX + 0.08, 1)
                    let newMaxY = clamp(base.maxY + dy, base.minY + 0.08, 1)
                    next = CGRect(x: base.minX, y: base.minY,
                                  width: newMaxX - base.minX, height: newMaxY - base.minY)
                }
                rect = next
            }
                .onEnded { _ in startRect = nil }
    }

    private func moveGesture(fitted: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if startRect == nil { startRect = rect; touched = true }
                guard let base = startRect else { return }
                var next = base
                next.origin.x = clamp(base.minX + value.translation.width / fitted.width,
                                      0, 1 - base.width)
                next.origin.y = clamp(base.minY + value.translation.height / fitted.height,
                                      0, 1 - base.height)
                rect = next
            }
            .onEnded { _ in startRect = nil }
    }

    // MARK: - 工具

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
