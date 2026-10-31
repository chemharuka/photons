import PhotonsCore

/// One camera-side render request: everything the loupe needs to ask for a frame, with no
/// controller state mixed in.
///
/// It mirrors the camera's inputs to `RenderOptions` one-for-one (see `renderOptions()`), and carries
/// the three identity fields (`identity`, `documentHash`, `revision`) a caller uses to tell two
/// requests apart. P1 only defines the value; P3/P4 wire it to the controller.
public struct LoupeFrameRequest: Equatable, Sendable {

    /// Which pixels the frame is of — the document as edited, or the decode.
    public enum Source: String, Equatable, Sendable {
        case edited, decoded
    }

    public var identity: String
    public var documentHash: String
    public var revision: Int
    public var source: Source
    public var rungScale: Float
    public var contentRect: ImageRect?
    public var canvas: ImageSize
    /// 画布像素 / 内容像素 —— 与 `RenderOptions.scale` 同一个量（1:1 时为 1）。
    public var scale: Double
    public var display: DisplayOptions
    public var neverUpscalesContent: Bool

    public init(identity: String, documentHash: String, revision: Int,
                source: Source = .edited, rungScale: Float,
                contentRect: ImageRect? = nil, canvas: ImageSize, scale: Double,
                display: DisplayOptions = DisplayOptions(),
                neverUpscalesContent: Bool = false) {
        self.identity = identity
        self.documentHash = documentHash
        self.revision = revision
        self.source = source
        self.rungScale = rungScale
        self.contentRect = contentRect
        self.canvas = canvas
        self.scale = scale
        self.display = display
        self.neverUpscalesContent = neverUpscalesContent
    }

    /// 映射到 `RenderOptions`（`photonsCore` 的那个），字段一一对应：
    /// canvas / scale = 本结构的 scale / outputWindow = contentRect / display /
    /// source = .edited → .edited、.decoded → .decoded /
    /// neverUpscalesContent / wantsPixels = false / useCache = true。
    public func renderOptions() -> RenderOptions {
        let renderSource: RenderSource = source == .decoded ? .decoded : .edited
        return RenderOptions(canvas: canvas,
                             scale: scale,
                             outputWindow: contentRect,
                             display: display,
                             useCache: true,
                             wantsPixels: false,
                             neverUpscalesContent: neverUpscalesContent,
                             source: renderSource)
    }
}

/// The renderer's answer to one `LoupeFrameRequest`.
///
/// The receipt keeps the request it answers (so a late frame can be matched to what asked for it)
/// and reports the actual canvas/photo rectangle plus the stage timings the renderer measured.
public struct LoupeFrameReceipt: Equatable, Sendable {

    public var request: LoupeFrameRequest
    public var canvas: ImageSize
    public var photoRect: ImageRect
    public var stages: [String]
    public var milliseconds: Double

    public init(request: LoupeFrameRequest, canvas: ImageSize, photoRect: ImageRect,
                stages: [String], milliseconds: Double) {
        self.request = request
        self.canvas = canvas
        self.photoRect = photoRect
        self.stages = stages
        self.milliseconds = milliseconds
    }
}
