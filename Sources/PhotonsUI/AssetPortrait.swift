import Foundation
import PhotonsCatalog
import PhotonsCore

/// 436/472 — one answer to "is this photo portrait?", shared by every surface that shapes its
/// picture box by orientation: the grid's 3:4 swatch (431) and the filmstrip's 1:1 square (472).
/// One implementation, so the two surfaces can never disagree about which photos are portrait.
///
/// The decision reads the **document's output** first: the record's `width/height` are display
/// pixels (import and the v7 migration apply EXIF orientation), and the user's crop can turn a
/// landscape frame into a portrait output, so the crop is laid over those pixels here. Only the
/// row is read: no decode, no file IO. `nil` means "no answer from the document" (unreadable JSON,
/// no crop, or a zero-sized output) and the caller falls back to the record's own pair.
/// **Unknown is landscape** — an old library missing metadata must look like today's landscape
/// frame, not like an empty box.
enum AssetPortrait {

    static func isPortrait(_ asset: Asset) -> Bool {
        let key = portraitKey(asset)
        if let cached = portraitAnswers.object(forKey: key) { return cached.boolValue }
        let answer: Bool
        if let fromDocument = documentIsPortrait(asset) {
            answer = fromDocument
        } else if let w = asset.width, let h = asset.height, w > 0, h > 0 {
            answer = h > w
        } else {
            answer = false
        }
        portraitAnswers.setObject(NSNumber(value: answer), forKey: key)
        return answer
    }

    /// 436 — one `Bool` per row version, never an `EditModel`. Measured at **~0.8 ms/cell** cold for
    /// a cropped document (A⑦), over 40 cells on one screen; a warm answer is a dictionary lookup.
    /// The key carries the row's own version stamp, so a crop edit invalidates it: same id, same
    /// `develop_version`/`edit_time` and same pixels is the same document.
    private static let portraitAnswers: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 4096
        return cache
    }()

    private static func portraitKey(_ asset: Asset) -> NSString {
        "\(asset.id)#\(asset.developVersion)#\(asset.editTime ?? "")#"
            + "\(asset.width ?? -1)x\(asset.height ?? -1)#\(asset.developJson.hashValue)"
            as NSString
    }

    /// The document crop over the row's pixels, or nil when there is nothing to add to the record.
    private static func documentIsPortrait(_ asset: Asset) -> Bool? {
        guard let w = asset.width, let h = asset.height, w > 0, h > 0 else { return nil }
        guard let data = asset.developJson.data(using: .utf8),
              let edit = try? JSONDecoder().decode(EditModel.self, from: data) else { return nil }
        // A full-frame crop outputs exactly the row's pixels — the fallback already answers that.
        guard !edit.geometry.cropRect.coversFrame else { return nil }
        let output = edit.geometry.outputPixels(in: ImageSize(width: w, height: h))
        guard output.width > 0, output.height > 0 else { return nil }
        return output.height > output.width
    }
}
