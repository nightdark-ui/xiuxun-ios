import SwiftUI

/// 大屏（iPad）布局辅助
enum AppLayout {
    /// 内容最大宽度：手机上不限制，iPad 上居中限宽
    static func readableWidth(_ geometry: GeometryProxy) -> CGFloat {
        min(geometry.size.width, 860)
    }

    /// 网格列数：按可用宽度算
    static func columns(for width: CGFloat, minimum: CGFloat = 160, spacing: CGFloat = 10) -> [GridItem] {
        let usable = min(width, 1100) - 28
        let count = max(1, Int(usable / (minimum + spacing)))
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: min(count, 5))
    }
}
