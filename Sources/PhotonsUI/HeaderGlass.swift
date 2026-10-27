import AppKit

/// 顶栏背后的**系统材质**。
///
/// 用户要的是「红绿灯回到系统原生外观（含液态玻璃）」。三颗按钮本来就是 AppKit 画的
/// （`standardWindowButton`），没人自画过它们；问题是 `.fullSizeContentView` 让 contentView
/// 铺到标题栏后面，而顶栏在那块区域里填了一层 0.96 不透明的 `windowBackgroundColor` ——
/// 玻璃的采样背景被这块底板挡死，系统按钮看上去就成了「自画的扁平圆点」。
///
/// 所以这里做的事只有一件：把那条顶栏换成 `.headerView` / `.behindWindow` 的材质。
/// 按钮的尺寸、位置、点击、失焦变灰全部仍然归 AppKit；这一层不碰它们，只是补上它们缺的玻璃。
///
/// `hitTest` 返回 `nil`：它是一层背景，不许从标题栏那里抢走拖动和点击（`isMovableByWindowBackground`
/// 是 `false`，窗口只能靠标题栏那条拖）。
public final class HeaderGlassView: NSVisualEffectView {

    public init() {
        super.init(frame: .zero)
        material = .headerView
        blendingMode = .behindWindow
        // 明/暗外观、窗口失焦都由材质自己跟，代码里不写死任何颜色。
        state = .followsWindowActiveState
        autoresizingMask = [.width]
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
