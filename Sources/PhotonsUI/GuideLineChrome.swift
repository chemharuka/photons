import AppKit
import CoreGraphics

// MARK: - 367 引导线: 「一眼看见」
//
// 334/337/348/354 made the guide lines *work*: two drawn lines become a keystone, the endpoints are
// source pixels, and the screen position is re-projected every frame. The user's report of
// 2026-11-10 was about a different half — 「现在的引导线不明显」:
//
//   · the colour was `NSColor.white` at 55 % opacity, which over a bright sky is the 「灰白」 the
//     user named;
//   · the stroke was 1.5 pt with a 1 px shadow, the same numbers as 328's 画线拉直 line;
//   · nothing marked the two ends, so the line looked like a scratch rather than a segment with
//     handles.
//
// This file is only the **chrome**: one place for the numbers the overlay strokes, so the colour can
// be changed without touching the arithmetic and so a test can name what was drawn. 328's own line
// keeps its 1.5 pt white (`CropDrawStraighten.lineWidth`), because 「画线拉直」 is a 0.3 s flash and
// 「引导线」 is standing chrome the user reads the picture against.
//
// `#22D3EE` (青蓝) was chosen against the existing palette: it does not collide with the frame white,
// the rejected red, the 35 % grid, or the `#202020` backdrop, and it has contrast on sky, foliage and
// skin. `lineWidth` 2.5 pt + `shadowWidth` 1.5 pt keeps a dark hairline outside the colour, so the
// line also reads on a white wall. The dots are the endpoint markers: a filled disc of radius 4 pt
// with a 1 pt black ring, drawn at the same alpha as the line (a rejected line's dots are red too).
public enum GuideLineChrome {
    /// The accepted line's colour — `#22D3EE`.
    public static let acceptedColour = NSColor(srgbRed: 0.13, green: 0.83, blue: 0.93, alpha: 1)
    /// The line's own width, in points (328's line stays 1.5).
    ///
    /// 2026-11-11 (user): 「引导线粗细再细一些」 — 2.5 → **2.0 pt**. Still thicker than 328's 1.5
    /// (the user's original complaint was that the line was not visible), but no longer the
    /// heavy stroke 367 shipped. The halo keeps its 1.5 pt so the colour still reads on a white wall.
    public static let lineWidth: CGFloat = 2.0
    /// The black halo's width on each side, in points (widened with the line).
    public static let shadowWidth: CGFloat = 1.5
    /// The endpoint disc's radius, in points (diameter 8 pt).
    public static let dotRadius: CGFloat = 4.0
    /// The black ring outside the endpoint disc, in points.
    public static let dotRingWidth: CGFloat = 1.0
    /// The accepted lines' standing opacity (337's 0.55 was 「看不见」 on a bright background).
    public static let acceptedAlpha: Double = 0.9
}
