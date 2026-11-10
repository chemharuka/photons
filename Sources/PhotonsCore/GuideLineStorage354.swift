import Foundation

// MARK: - 354 · 引导线 that survive the crop session
//
// A guide line's endpoints are **source pixels** (`GuideLine.a/b` in `PhotonsUI`), so they can be
// stored without a screen: two doubles per end. The axis is the one thing the pixels do not carry —
// it is the user's *intent* (「这条本该是竖的」), decided by the stroke's screen angle when it was
// drawn, so it is stored beside them as a flag.
//
// Encoding discipline: the key is written **only when the list is non-empty** (the
// `quarterTurns`/`perspectiveVertical` rule). A document with no guide lines re-encodes byte for
// byte, which is what `render-edit-neutral`'s pinned blob depends on; and nothing here enters the
// geometry **key material** — a guide line is not a pixel, so it must not move a cache key.
public struct StoredGuideLine: Sendable, Equatable, Codable {
    public var ax: Double
    public var ay: Double
    public var bx: Double
    public var by: Double
    /// `true` = 竖 (this line should end up vertical), `false` = 横.
    public var vertical: Bool

    public init(ax: Double, ay: Double, bx: Double, by: Double, vertical: Bool) {
        self.ax = ax
        self.ay = ay
        self.bx = bx
        self.by = by
        self.vertical = vertical
    }
}
