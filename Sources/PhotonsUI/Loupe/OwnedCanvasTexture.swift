import Foundation
import Metal
import PhotonsCore

/// 谁拥有这张纹理。`.graph` 才回渲染池；`.cacheCopy` 是 434 缓存自己 blit 出来的副本（回池 = 438
/// 的黑画布）；`.borrowed` 是同一函数栈内的借用（`FrozenFrame` 那种，由 `canvasTexture` 保活）。
public enum CanvasTextureOwner: Equatable {
    case graph(RenderGraph)
    case cacheCopy
    case borrowed

    public static func == (lhs: CanvasTextureOwner, rhs: CanvasTextureOwner) -> Bool {
        switch (lhs, rhs) {
        case (.cacheCopy, .cacheCopy), (.borrowed, .borrowed):
            return true
        case let (.graph(a), .graph(b)):
            return a === b
        default:
            return false
        }
    }
}

/// 440 — 「这张纹理归谁」是类型里的一个字段，而不是调用方的一个 `if`。
///
/// 437/438 的崩溃都在同一处：`(texture, graph?)` 把所有权留给调用方猜，于是缓存自己 blit 出来的
/// 副本被当成渲染池的纹理还了回去，池又把它发给下一帧当暂存目标。这里把声明搬进类型：
/// `recycle()` 只看 `owner`，只有 `.graph` 真的回池。
public struct OwnedCanvasTexture {
    public let texture: MTLTexture
    public let owner: CanvasTextureOwner

    /// 验收断言用：`.cacheCopy` / `.borrowed` 上调用 `recycle()` 的次数。它是「有人还想用旧接口
    /// 猜所有权」的信号；正常路径只在 `.graph` 上回收。
    public nonisolated(unsafe) private(set) static var refusedRecycles = 0

    public init(texture: MTLTexture, owner: CanvasTextureOwner) {
        self.texture = texture
        self.owner = owner
    }

    public var isGraphOwned: Bool {
        if case .graph = owner { return true }
        return false
    }

    /// 只有 `.graph` 才真的回池；其余是 no-op（并计数 `refusedRecycles`，供验收断言）。
    ///
    /// **队列是必填参数，不是默认行为**：`present` 既可能在渲染队列上跑（真帧落地），也可能在
    /// 主线程上跑（434 缓存命中、桥的收尾）。`TexturePool` 的 idle 表没有锁、只允许渲染队列碰，
    /// 所以 hop 由这里替调用方做掉 —— 440 的第一版把 `queue.async` 丢了，那等于在主线程上改池的字典。
    public func recycle(on queue: DispatchQueue) {
        switch owner {
        case .graph(let graph):
            queue.async { graph.recycle(output: texture) }
        case .cacheCopy, .borrowed:
            queue.async { Self.refusedRecycles += 1 }
        }
    }
}
