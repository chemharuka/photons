import Foundation
import QuartzCore
import PhotonsCore

/// 画布上此刻是什么。§20 的 P1 只把它**写下来**：没有任何绘制路径读它。
public enum CanvasContent: Equatable {
    /// 什么都没有（拆窗、刚建好、照片还没到）。
    case empty
    /// 311 的 stand-in：缩略图占位。`photo` 是它属于哪张照片（换图时必须一起换）。
    case placeholder(ThumbFrame)
    /// 037② 的低清全幅底图。
    case lowRes(BackdropFrame)
    /// 真帧。`settled == false` 是 434 缓存命中画上来的副本（还没有本帧的渲染）。
    case frame(OwnedCanvasTexture, settled: Bool)

    public static func == (lhs: CanvasContent, rhs: CanvasContent) -> Bool {
        switch (lhs, rhs) {
        case (.empty, .empty):
            return true
        case let (.placeholder(a), .placeholder(b)):
            return a == b
        case let (.lowRes(a), .lowRes(b)):
            return a == b
        case let (.frame(a, settledA), .frame(b, settledB)):
            return settledA == settledB && a.texture === b.texture
        default:
            return false
        }
    }

    /// 测试访问器与转移记录用的稳定拼写：`empty` / `placeholder(B)` /
    /// `lowRes(photo)` / `frame(settled:false)`。
    public var label: String {
        switch self {
        case .empty:
            return "empty"
        case let .placeholder(thumb):
            return "placeholder(\(thumb.photo))"
        case let .lowRes(backdrop):
            return "lowRes(\(backdrop.photo ?? "nil"))"
        case let .frame(_, settled):
            return "frame(settled:\(settled))"
        }
    }
}

public struct ThumbFrame: Equatable {
    public let photo: String
    public let pixelSize: ImageSize?

    public init(photo: String, pixelSize: ImageSize?) {
        self.photo = photo
        self.pixelSize = pixelSize
    }
}

public struct BackdropFrame: Equatable {
    public let photo: String?
    public let key: String?

    public init(photo: String?, key: String?) {
        self.photo = photo
        self.key = key
    }
}

/// §20 的 P1：状态先存在、先被证明「写得对」。没有任何绘制路径读它 ——
/// `LoupeController` 里只有两处写入（`show` / `hold`）和两个 `*ForTesting` 访问器。
public struct CanvasPresentation: Equatable {
    public private(set) var content: CanvasContent = .empty
    /// 手势冻结期间保活的那张（`frozenFrame` 的纹理）。P1 只记录，不做决定。
    public private(set) var held: OwnedCanvasTexture?
    /// 状态变了几次、最后一次为什么变 —— 让 §3③ 的序列断言可写，也让下一单能先对账再改行为。
    public private(set) var transitions: [Transition] = []

    public struct Transition: Equatable {
        public let to: String
        public let reason: String
        public let at: Double

        public init(to: String, reason: String, at: Double) {
            self.to = to
            self.reason = reason
            self.at = at
        }
    }

    public init() {}

    public static func == (lhs: CanvasPresentation, rhs: CanvasPresentation) -> Bool {
        lhs.content == rhs.content
            && lhs.transitions == rhs.transitions
            && sameTexture(lhs.held, rhs.held)
    }

    private static func sameTexture(_ lhs: OwnedCanvasTexture?,
                                    _ rhs: OwnedCanvasTexture?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.texture === rhs.texture
        default:
            return false
        }
    }

    /// P1 的唯一有内容的部分：**只记录，不判断谁能覆盖谁，不 `recycle()`。**
    /// 同值重复写入不产生转移。
    public mutating func show(_ next: CanvasContent, reason: String) {
        guard next != content else { return }
        content = next
        transitions.append(Transition(to: next.label, reason: reason, at: CACurrentMediaTime()))
    }

    /// 记录手势冻结期间保活的那张纹理。同值重复写入不产生转移；不清 `content`。
    public mutating func hold(_ texture: OwnedCanvasTexture?, reason: String) {
        guard !Self.sameTexture(texture, held) else { return }
        held = texture
        transitions.append(Transition(to: texture == nil ? "held(nil)" : "held",
                                      reason: reason, at: CACurrentMediaTime()))
    }
}
