import SwiftUI

/// 启动品牌页（对齐安卓版：「AI小助手 / 作者：Night / 正在打开库存…」）
struct SplashView: View {
    @State private var fadeIn = false

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

                Rectangle()
                    .fill(UI.orange.opacity(0.18))
                    .frame(width: 120, height: 1)
                    .padding(.top, 4)
            }
            .opacity(fadeIn ? 1 : 0)
            .scaleEffect(fadeIn ? 1 : 0.96)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.35)) { fadeIn = true }
        }
    }
}
