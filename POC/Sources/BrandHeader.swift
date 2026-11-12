import SwiftUI

/// 三页统一的品牌栏：圆形头像 + 标题 + 作者
struct BrandHeader: View {
    var subtitle: String = "作者：Night"
    var showsSettings: Bool = false
    var onSettings: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image("LaunchLogo")
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(Circle())
                .overlay(Circle().stroke(UI.orange.opacity(0.25), lineWidth: 1))

            VStack(alignment: .leading, spacing: 1) {
                Text("PicSeek搜图")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(UI.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(UI.textSecondary)
            }

            Spacer()

            if showsSettings, let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18))
                        .foregroundColor(UI.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
