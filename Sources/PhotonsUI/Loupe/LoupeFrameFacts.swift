import Foundation
import PhotonsCore

/// 439 — the frame's **identity facts**, computed in one place.
///
/// A frame's cache key used to be assembled at each call site: the backdrop spelled the photo, the
/// develop inputs, the digest, the ceiling and the geometry; the canvas spelled fifteen fields; the
/// histogram spelled the digest again. Each copy was free to drift, and a drift is silent — the key
/// simply never matches, or (worse) matches a picture it does not describe. This value is the one
/// place those facts are read off the document and the camera; `BackdropCache.Key(facts:)` and
/// `CanvasFrameCache.Key(facts:)` only project it into their own byte format.
///
/// The value is deliberately pure: it knows nothing about the controller, the session or the
/// presenter. Everything the caller already owns is passed in (`photo`, `primaries`, the viewport and
/// the mode), so a key can never depend on a second read of live state.
public struct LoupeFrameFacts: Equatable, Sendable {
    /// The photo: `contentHash|assetID`, or a harness' frame-source identity.
    public let photo: String
    /// `edit.decodeInputs.key` — the decoder-side half of the document.
    public let decodeInputs: String
    /// `Histogram.editDigest(edit)` — the renderer-side half.
    public let editDigest: String
    /// `EditModel.geometryFingerprint` — the spelled geometry (crop/rotation/flip/…).
    public let geometry: String
    /// The picture's ceiling in linear light (`HighlightCeiling.current` unless overridden).
    public let ceiling: Double
    /// `canvasCacheCameraToken(state)` — mode, zoom and centre.
    public let camera: String
    /// The canvas, in device pixels.
    public let viewport: ImageSize
    /// `canvasCacheModeToken(mode)` — `.edited` / `.original` / `.compare(axis,fraction)`.
    public let mode: String
    /// The crop workspace's fit multiplier.
    public let fitScale: Double
    /// `CanvasRole.rawValue` (`document` / `export`).
    public let canvasRole: String
    /// Whether the crop tool is on.
    public let cropIsActive: Bool
    /// The clipping-warning grid is drawn into the frame's pixels.
    public let highlightWarning: Bool
    /// The display headroom (`DisplayOptions.headroom`).
    public let headroom: Double
    /// The rung the frame was rendered from.
    public let decodeScale: Double
    /// `OutputPrimaries.rawValue` — the presenter's storage decides the S4 matrix.
    public let primaries: String

    /// The backdrop's facts: the five document fields and nothing else.
    ///
    /// 440 — the backdrop projection is keyed by the document alone; it reads only `photo`,
    /// `decodeInputs`, `editDigest`, `ceiling` and `geometry`. The canvas-side fields are filled with
    /// the neutral spellings so this value is still complete, but no caller can mistake them for a
    /// camera it supplied. `digestSuffix` is the one caller-side modifier (144's preview marker),
    /// applied after the digest so the settled key keeps exactly `Histogram.editDigest(edit)`.
    public init(documentOnly photo: String, edit: EditModel,
                ceiling: Double = HighlightCeiling.current,
                digestSuffix: String = "") {
        self.init(photo: photo, edit: edit, ceiling: ceiling,
                  camera: .fit, viewport: ImageSize(width: 1, height: 1), mode: .edited,
                  fitScale: 0, canvasRole: .document, cropIsActive: false,
                  highlightWarning: false, headroom: 0, decodeScale: 1,
                  primaries: .displayP3, digestSuffix: digestSuffix)
    }

    /// The canvas' facts: every field that reaches the canvas pixels, **no defaults**.
    ///
    /// 440 — a missing `highlightWarning` used to default to `false`, which is the one wrong direction:
    /// the key would say "no warning" while the pixels carry the grid, i.e. a false hit. Every canvas
    /// key must spell every field.
    public init(canvas photo: String, edit: EditModel,
                camera: LoupeViewState,
                viewport: ImageSize,
                mode: LoupeFrameMode,
                fitScale: Double,
                canvasRole: CanvasRole,
                cropIsActive: Bool,
                highlightWarning: Bool,
                headroom: Double,
                decodeScale: Double,
                primaries: OutputPrimaries,
                ceiling: Double,
                digestSuffix: String) {
        self.init(photo: photo, edit: edit, ceiling: ceiling,
                  camera: camera, viewport: viewport, mode: mode, fitScale: fitScale,
                  canvasRole: canvasRole, cropIsActive: cropIsActive,
                  highlightWarning: highlightWarning, headroom: headroom,
                  decodeScale: decodeScale, primaries: primaries, digestSuffix: digestSuffix)
    }

    /// The one designated initialiser: the five document fields (`decodeInputs`, `editDigest`,
    /// `geometry`, `ceiling`) and the two camera spellings are read here and nowhere else.
    private init(photo: String, edit: EditModel, ceiling: Double,
                 camera: LoupeViewState, viewport: ImageSize, mode: LoupeFrameMode,
                 fitScale: Double, canvasRole: CanvasRole, cropIsActive: Bool,
                 highlightWarning: Bool, headroom: Double, decodeScale: Double,
                 primaries: OutputPrimaries, digestSuffix: String) {
        self.photo = photo
        self.decodeInputs = edit.decodeInputs.key
        self.editDigest = Histogram.editDigest(edit) + digestSuffix
        self.geometry = edit.geometryFingerprint
        self.ceiling = ceiling
        self.camera = Self.canvasCacheCameraToken(camera)
        self.viewport = viewport
        self.mode = Self.canvasCacheModeToken(mode)
        self.fitScale = fitScale
        self.canvasRole = canvasRole.rawValue
        self.cropIsActive = cropIsActive
        self.highlightWarning = highlightWarning
        self.headroom = headroom
        self.decodeScale = decodeScale
        self.primaries = primaries.rawValue
    }

    static func canvasCacheCameraToken(_ state: LoupeViewState) -> String {
        "\(state.mode.rawValue)|z=\(String(format: "%.17g", state.zoom))"
            + "|cx=\(String(format: "%.17g", state.centerX))"
            + "|cy=\(String(format: "%.17g", state.centerY))"
    }

    static func canvasCacheModeToken(_ mode: LoupeFrameMode) -> String {
        switch mode {
        case .edited: return "edited"
        case .original: return "original"
        case .compare(let split):
            return "compare(\(split.axis.rawValue),\(String(format: "%.17g", split.fraction)))"
        }
    }
}
