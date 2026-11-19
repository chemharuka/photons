import Foundation

/// 436 — the pixel size **as the photo is displayed**, from the stored size and the EXIF orientation.
///
/// `assets.width/height` are display pixels: the dimensions a decoder produces after applying the
/// orientation. `MetadataReader` keeps reading `kCGImagePropertyPixelWidth/Height`, which is the
/// *stored* size (EXIF orientation is not baked into it); import and the v7 migration pass that
/// through this function so the row agrees with the bitmap the grid shows.
///
/// Only the quarter turns (5…8) swap the axes. Orientations 1…4 and a missing/unknown value return
/// the pair unchanged — including a nil in either dimension, because an old row may have one and
/// swapping must never turn "unknown" into a crash. EXIF 2/4/5/7 are mirrored, and mirroring does
/// not change the extent, so the swap rule is the whole of it.
public enum PixelUpright {
    public static func upright(width: Int?, height: Int?,
                               orientation: Int?) -> (width: Int?, height: Int?) {
        guard let orientation, (5...8).contains(orientation),
              let width, let height else {
            return (width, height)
        }
        return (height, width)
    }
}
