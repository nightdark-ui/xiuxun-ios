import SwiftUI

/// 启动品牌页（对齐安卓版：「AI小助手 / 作者：Night / 正在打开库存…」）
struct SplashView: View {
    @State private var fadeIn = false
    @State private var progress: CGFloat = 0.04

    var body: some View {
        ZStack {
            Color(red: 1.0, green: 0.980, blue: 0.965).ignoresSafeArea()

            VStack(spacing: 18) {
                Image("LaunchLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(UI.orange.opacity(0.25), lineWidth: 1))

                Text("PicSeek 搜图")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(UI.textPrimary)

                Text("作者：Night")
                    .font(.system(size: 13))
                    .foregroundColor(UI.textSecondary)

                Text("正在打开…")
                    .font(.system(size: 13))
                    .foregroundColor(UI.textSecondary)
                    .padding(.top, 6)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(UI.orange.opacity(0.16))
                        .frame(width: 140, height: 3)
                    Capsule()
                        .fill(UI.orange)
                        .frame(width: 140 * progress, height: 3)
                }
                .padding(.top, 10)
            }
            .opacity(fadeIn ? 1 : 0)
            .scaleEffect(fadeIn ? 1 : 0.96)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { fadeIn = true }
            withAnimation(.easeInOut(duration: 1.25)) { progress = 0.98 }
        }
    }
}
