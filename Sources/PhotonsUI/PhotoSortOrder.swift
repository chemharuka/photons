import Foundation
import PhotonsCatalog

/// 胶片条/网格/左侧栏共用的**拍摄时间排序**——一个视图偏好，不是文档数据。
///
/// Three rules this type exists to state once:
///
/// - **The button shows the state, not the action.** `label` is what the view is doing right now
///   (`新→旧` / `旧→新`), so there is no verb to decode and no risk of reading "排序" as a noun.
///   The icon is `arrow.up.arrow.down` — the generic sort glyph — and deliberately does **not**
///   change direction with the state: two places describing the same fact is how a toggle starts
///   lying about which end is which.
/// - **The sort key is the capture time** (`assets.capture_time`, the EXIF date the catalog already
///   orders the whole grid by). Not the filename, not the mtime, not the import order: a photo
///   renamed by the user still belongs where it was shot.
/// - **A photo with no capture time sorts last, in both directions**, and ties break on the
///   filename, then on the id. A missing EXIF date is a fact about the file, not a very old or a
///   very new photo, so it must not move to the front just because the arrow flipped — and a total
///   order (id as the last key) is what keeps `sorted` deterministic when two roots hold the same
///   filename.
///
/// Nothing here is persisted or in history: the value lives in `CatalogSession.sortOrder`, and
/// `PhotoSortPreferences` only remembers which of the two the user last chose.
public enum PhotoSortOrder: String, CaseIterable, Sendable {

    /// Newest capture first — the catalog's own order (`ORDER BY capture_time DESC`), and the
    /// default: a photo bag opens on the pictures you just shot.
    case newestFirst
    /// Oldest capture first.
    case oldestFirst

    public static let `default`: PhotoSortOrder = .newestFirst

    /// The generic sort glyph. Static on purpose — see the note at the top of this file.
    public static let symbol = "arrow.up.arrow.down"

    /// What the button says: the order in force, arrow included.
    public var label: String {
        switch self {
        case .newestFirst: return "新→旧"
        case .oldestFirst: return "旧→新"
        }
    }

    /// The hover text: names the key *and* the order, because the label alone does not say what is
    /// being ordered (date? name? rating?).
    public var tooltip: String { "按拍摄时间排序：\(label)" }

    /// What one click does. `newestFirst ⇄ oldestFirst`.
    public var toggled: PhotoSortOrder {
        self == .newestFirst ? .oldestFirst : .newestFirst
    }

    /// The direction on the capture time alone, for a caller that already knows both photos have one.
    public func isDescending() -> Bool { self == .newestFirst }

    // MARK: ordering

    /// The capture-time key of one asset, or nil when the file carries no EXIF date.
    ///
    /// `assets.capture_time` is ISO-8601 UTC written with second precision
    /// (`2026-10-02T05:57:31Z`), i.e. lexicographic order **is** chronological order — the same key
    /// the SQL `ORDER BY a.capture_time DESC` uses, so a sorted array here and a query there cannot
    /// disagree about what "newest" means. An empty string is treated as missing: a row with `""`
    /// is a row without a date in every way that matters to the user.
    public static func captureKey(_ asset: Asset) -> String? {
        guard let raw = asset.captureTime, !raw.isEmpty else { return nil }
        return raw
    }

    /// `a` comes before `b` in this order. Total: two different assets never compare equal.
    public func ordersBefore(_ a: Asset, _ b: Asset) -> Bool {
        let ka = Self.captureKey(a)
        let kb = Self.captureKey(b)
        switch (ka, kb) {
        case let (.some(ta), .some(tb)):
            if ta != tb { return isDescending() ? ta > tb : ta < tb }
        case (.some, .none):
            return true                      // a dated photo outranks an undated one, both ways
        case (.none, .some):
            return false
        case (.none, .none):
            break                            // both undated: fall through to the filename
        }
        // Ties (equal timestamps, or two undated files): filename, then id. Ascending in **both**
        // directions — a tie is not a direction, and flipping it would make two photos of the same
        // second swap places depending on which way the arrow points.
        if a.filename != b.filename { return a.filename < b.filename }
        return a.id < b.id
    }

    /// The array in this order. `Array.sorted` with a total order, so the result is deterministic
    /// (no dependence on the input order, which is what makes "re-sort in place" equal to
    /// "re-query from the catalog").
    public func sorted(_ assets: [Asset]) -> [Asset] {
        assets.sorted { ordersBefore($0, $1) }
    }
}

/// Which order the user last chose — **one global preference**, like `photons.browserMode`, not a
/// per-library archive like the filter bar: "I read my photos oldest first" is a habit, not a
/// property of one shoot.
///
/// Total on read: an unknown or hand-edited raw value degrades to `.default` instead of throwing or
/// leaving the session without an order. The key carries `v1` so a future shape writes beside this
/// blob rather than over it.
public enum PhotoSortPreferences {

    public static let key = "photons.sortOrder.v1"

    /// The slice of `UserDefaults` this file needs, narrowed so a test substitutes its own store and
    /// no other code path can reach the domain through it. The method names are distinct from
    /// `string(forKey:)` on purpose — an extension cannot redeclare what `UserDefaults` already has.
    public protocol Store: AnyObject {
        func sortOrderRaw(forKey key: String) -> String?
        func storeSortOrderRaw(_ raw: String?, forKey key: String)
    }

    /// The remembered order, or `.default` when nothing (usable) is stored.
    public static func recall(from store: Store) -> PhotoSortOrder {
        guard let raw = store.sortOrderRaw(forKey: key),
              let order = PhotoSortOrder(rawValue: raw) else { return .default }
        return order
    }

    /// Remember `order`. Equality-guarded at the call site (`CatalogSession.setSortOrder`), so a
    /// click that changes nothing does not write; one click is one write, which is cheap enough that
    /// this needs no throttle (unlike the filter bar's per-tick bursts).
    public static func remember(_ order: PhotoSortOrder, in store: Store) {
        store.storeSortOrderRaw(order.rawValue, forKey: key)
    }
}

extension UserDefaults: PhotoSortPreferences.Store {
    public func sortOrderRaw(forKey key: String) -> String? { string(forKey: key) }
    public func storeSortOrderRaw(_ raw: String?, forKey key: String) {
        if let raw { set(raw, forKey: key) } else { removeObject(forKey: key) }
    }
}
