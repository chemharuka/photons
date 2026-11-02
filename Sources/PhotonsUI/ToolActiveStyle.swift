import SwiftUI

// MARK: - 253: the one active-tool look

/// **The only place a tool's 「active」 colours are decided.**
///
/// The user's ask (2026-11-03): 「修复画笔点击后要变蓝……修复画笔按钮变蓝表示激活」. A `.bordered`
/// button's `.tint` does not paint its bezel, so 078's `.tint(healTool ? .accentColor : .secondary)`
/// was invisible. The visible blue is a **filled background**, exactly like the mask row's selected
/// marker (`MaskListPanel`) and the crop chips (`TransformPanel`).
///
/// Every tool button draws through this file:
///   · 修复 / 红眼 / 蒙版画笔 (their segmented controls are built from `ToolSegmentButton`);
///   · 白平衡吸管 (`InspectorView.dropperRow`);
///   · 点颜色吸管 (`PointColorSwatchStrip`);
///   · 蒙版亮度 / 色彩吸管 (`MaskEyedropperRow`).
///
/// Active = `Color.accentColor` fill + white glyph/text. Inactive = `.secondary` text + a clear
/// background, so the card's own material shows through. Both are functions, not literals in each
/// view: the acceptance can sample this view's pixels and deleting the accent here must break it.
public enum ToolActiveStyle {

    /// The button's fill: the system accent when armed, nothing when not.
    public static func fill(_ active: Bool) -> Color {
        active ? Color.accentColor : Color.clear
    }

    /// The glyph/text colour over that fill. White reads on the accent; secondary reads as a tool
    /// that is available but not armed.
    public static func foreground(_ active: Bool) -> Color {
        active ? Color.white : Color.secondary
    }
}

/// The shared shape of the fill, so every tool button is the same size and corner.
private struct ToolActiveModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .foregroundStyle(ToolActiveStyle.foreground(active))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ToolActiveStyle.fill(active))
            )
            .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

public extension View {
    /// Mark a button as the armed tool (or not). One implementation for every entry.
    func toolActive(_ active: Bool) -> some View {
        modifier(ToolActiveModifier(active: active))
    }
}

/// One cell of a tool's 修复/红眼 or 浏览/画笔/擦除 selector.
///
/// The native `.segmented` Picker already highlights its selection, but its unselected text is
/// primary and its selected fill is the system's own: 253 asks for the same accent fill + white text
/// as the rest of the tool buttons, so the two modes read as one control language. The action writes
/// the same `CatalogSession` field the Picker did; no tool behaviour moves.
public struct ToolSegmentButton: View {
    public let title: String
    public let active: Bool
    public let action: () -> Void

    public init(title: String, active: Bool, action: @escaping () -> Void) {
        self.title = title
        self.active = active
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .toolActive(active)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }
}
