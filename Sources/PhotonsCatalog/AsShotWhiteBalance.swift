import Foundation
import PhotonsCore

/// 540 — the as-shot white balance, stored with the library instead of waiting for a decode.
///
/// The inspector's 色温 / 色调 rows used to have a value only after the first development landed:
/// `DecoderCapabilities.asShotTemperature` / `asShotTint` travel with a decoded frame, so a photo
/// switch showed the previous photo's pair (or nothing) until that frame arrived. 530 made every
/// other slider ready in ~2 ms from `develop_json`; these two rows were the last ones left waiting.
///
/// The pair is a fact about the **file**, not about the document and not about a render, so it is
/// persisted once and read synchronously on a switch. `recordCapabilities` is still the source of
/// truth: an old/incorrect row is corrected from the first frame that lands, and the session counts
/// that as a mismatch. A row is never consulted for another asset.
///
/// **Why `settings` and not a new table.** The value is one small row per photo, the table has
/// existed since v1, and the dispatch's whitelist does not allow a schema migration that would have
/// to move `Schema.version` (and its smoke test) in the same change. A key per asset keeps the same
/// "one row per photo" shape without inventing a second migration surface for two numbers.
extension Catalog {

    /// The one spelling of a photo's row. Asset ids are UUIDs, so no escaping is needed.
    public static func asShotWhiteBalanceStorageKey(assetID: String) -> String {
        "as_shot_white_balance.\(assetID)"
    }

    /// The stored pair, or `nil` when this photo has never completed a development.
    ///
    /// Every failure is a miss, never an error at the UI: a missing row, a corrupt value, a library
    /// that predates 540. The caller then keeps today's behaviour (the rows have no number until
    /// the first frame).
    public func storedAsShotWhiteBalance(forAsset id: String) -> WhiteBalance? {
        guard let raw = try? setting(Self.asShotWhiteBalanceStorageKey(assetID: id)),
              let data = raw.data(using: .utf8),
              let pair = try? JSONDecoder().decode(WhiteBalance.self, from: data) else { return nil }
        guard pair.temperature != nil || pair.tint != nil else { return nil }
        return pair
    }

    /// Write the pair for one photo. Returns `false` when the library refused the write; the caller
    /// must not claim the value is durable in that case.
    ///
    /// Both fields are optional because the decoder may report only one usable axis; a pair with
    /// neither is not a measurement and is not stored.
    @discardableResult
    public func storeAsShotWhiteBalance(_ pair: WhiteBalance, forAsset id: String) -> Bool {
        guard pair.temperature != nil || pair.tint != nil else { return false }
        guard let data = try? JSONEncoder().encode(pair),
              let value = String(data: data, encoding: .utf8) else { return false }
        do {
            try writeSettings([Self.asShotWhiteBalanceStorageKey(assetID: id): value])
            return true
        } catch {
            return false
        }
    }
}
