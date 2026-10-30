import AppKit
import Metal
import PhotonsCore

/// 185 — **the ⌥ mask preview**: hold ⌥ and the canvas shows the `sharpMasking` mask, 0…1 as grey;
/// release it and the photograph comes back.
///
/// This is the Lightroom gesture the brief asks for (§1, §3「Alt 预览」), and the whole of its
/// contract is what it is **not**:
///
///   · it is **not** a document field — `EditModel` has no `showSharpenMask`, so the encoded JSON of a
///     document is byte-identical with ⌥ up or down (`EditSnapshot`, `History`, `Preset` never see it);
///   · it is **not** a render key — the mask comes from `RenderGraph.sharpenMaskPreview`, which is
///     outside `RenderKeyChain` and outside the stage cache, so holding ⌥ cannot evict a cached frame
///     or make the next render miss;
///   · it is **not** an edit — no history row, no `changedStages` bit, no decode.
///
/// It is one `CALayer` on the canvas whose contents is the mask, kept in step with the frame that is on
/// screen: the mask is rendered from the *same* canvas texture the last present drew, at the same size,
/// so it lines up to the pixel (including the letterbox, which the preview renders as `m = 0`).
public final class SharpenMaskPreview {

    /// The mask overlay. `nil` until something is shown.
    private var overlay: CALayer?
    private var monitor: Any?

    /// Called on every ⌥ transition. The loupe re-presents its frozen frame from this, which is what
    /// makes the preview appear the instant the key goes down rather than at the next render.
    public var onToggle: ((Bool) -> Void)?

    public init() {}

    public static func shouldShow(flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option)
    }

    /// Watch ⌥ for as long as the window lives. Idempotent: a second install replaces the first.
    public func install() {
        uninstall()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let show = Self.shouldShow(flags: event.modifierFlags)
            if show != self.isShowing {
                self.isShowing = show
                self.onToggle?(show)
            }
            return event
        }
    }

    public func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Whether the mask is on the canvas. Read-only from outside: only ⌥ (or `hide()`) moves it.
    public private(set) var isShowing = false

    /// Take the mask off the canvas without touching the key state — a resize, a teardown, a failure.
    public func hide(in canvasLayer: CAMetalLayer? = nil) {
        if canvasLayer == nil || overlay?.superlayer === canvasLayer {
            overlay?.removeFromSuperlayer()
            overlay = nil
        }
    }

    /// Draw (or clear) the mask for `texture` — the canvas the last present put on screen.
    ///
    /// A GPU failure clears the overlay instead of throwing: the preview is a display aid, and a mask
    /// that cannot be computed must look like "nothing shown", never like a broken canvas.
    public func refresh(in canvasLayer: CAMetalLayer, graph: RenderGraph,
                        texture: MTLTexture, edit: EditModel) {
        guard isShowing, edit.hasSharpen else {
            hide(in: canvasLayer)
            return
        }
        guard let image = try? graph.sharpenMaskPreview(from: texture, edit: edit),
              let cg = Self.cgImage(of: image) else {
            hide(in: canvasLayer)
            return
        }
        let layer: CALayer
        if let existing = overlay, existing.superlayer === canvasLayer {
            layer = existing
        } else {
            layer = CALayer()
            // Above the metal layer's own content, below nothing else: the mask covers the picture.
            layer.contentsGravity = .resize
            layer.zPosition = 1
            canvasLayer.addSublayer(layer)
            overlay = layer
        }
        layer.frame = canvasLayer.bounds
        layer.contents = cg
    }

    /// 8-bit RGBA image of a grey mask. The mask is a coverage value in 0…1, so 8 bits is four times
    /// the precision the eye has in it, and it keeps the layer's `contents` cheap to build.
    static func cgImage(of image: DisplayImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0 ..< (w * h) {
            let v = max(0, min(255, Int((Float(image.rgba[i * 4]) * 255).rounded())))
            bytes[i * 4] = UInt8(v)
            bytes[i * 4 + 1] = UInt8(v)
            bytes[i * 4 + 2] = UInt8(v)
            bytes[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
