import SwiftUI

/// 与安卓版对齐的视觉语言。
/// 安卓：Theme.kt（AppCard / CardHeader / PrimaryButton / DashedBox / Segmented …）
enum UI {
    static let orange = Color(red: 0.94, green: 0.33, blue: 0.13)
    static let pageBackground = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let cardBackground = Color.white
    static let textPrimary = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let textSecondary = Color(red: 0.45, green: 0.45, blue: 0.48)
    static let divider = Color(red: 0.90, green: 0.90, blue: 0.92)
    static let radius: CGFloat = 16
}

/// 卡片容器（安卓 AppCard）
struct AppCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UI.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: UI.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UI.radius, style: .continuous)
                    .stroke(UI.divider, lineWidth: 0.8)
            )
    }
}

/// 卡片标题行（安卓 CardHeader）
struct CardHeader: View {
    let title: String
    var trailing: String = ""
    var leading: String = ""

    var body: some View {
        HStack(spacing: 6) {
            if !leading.isEmpty {
                Text(leading).font(.subheadline)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(UI.textPrimary)
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundColor(UI.orange)
            }
        }
    }
}

/// 主按钮（安卓 PrimaryButton）
struct PrimaryButton: View {
    let title: String
    var enabled: Bool = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(enabled ? UI.orange : UI.orange.opacity(0.35))
                .foregroundColor(.white)
                .clipShape(Capsule())
        }
        .disabled(!enabled)
    }
}

/// 虚线框（安卓 DashedBox）——"客户来图"区域
struct DashedBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 8) { content }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(UI.orange.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        UI.orange.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                    )
            )
    }
}

/// 分段控件（安卓 Segmented）
struct Segmented: View {
    let options: [String]
    @Binding var selected: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, title in
                Button {
                    selected = index
                } label: {
                    Text(title)
                        .font(.system(size: 12, weight: index == selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(index == selected ? UI.orange : Color.clear)
                        .foregroundColor(index == selected ? .white : UI.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(UI.pageBackground)
        .clipShape(Capsule())
    }
}

/// 开关行（安卓 ToggleRow）
struct ToggleRow: View {
    let title: String
    var subtitle: String = ""
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14)).foregroundColor(UI.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundColor(UI.textSecondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn).labelsHidden().tint(UI.orange)
        }
    }
}

/// 细进度条（安卓 ThinProgress）
struct ThinProgress: View {
    let value: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(UI.divider)
                Capsule()
                    .fill(UI.orange)
                    .frame(width: max(4, geo.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

/// 小标签（安卓 PillTag）
struct PillTag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(UI.orange.opacity(0.12))
            .foregroundColor(UI.orange)
            .clipShape(Capsule())
    }
}

/// 提示文字（安卓 Hint）
struct Hint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(UI.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HLine: View {
    var body: some View { Divider().background(UI.divider) }
}
