import AppKit
import CryptoKit
import Foundation
import PhotonsCatalog

/// 043 — the filter bar's slots and values, remembered **per library**.
///
/// The filter is view state, not document data: it is not in the catalog, it never enters history,
/// and it must not gain a migration ladder. So it lives in `UserDefaults`, one key per library.
///
/// Two rules hold everything here together:
///
/// - **The key is a hash, not the path.** A raw path in a defaults key carries the user name and
///   often CJK, which `CFPreferences` logs about and occasionally drops; 16 hex digits of SHA-256
///   keep two libraries with the same folder name apart and keep the key readable in `defaults read`.
/// - **Reading back is total.** A blob that is stale, hand-edited or from a future schema degrades
///   to *fewer slots*, never to "this library will not open": unknown dimension → drop that slot,
///   more than five slots → keep the first five, a repeated dimension → keep the first one. Values
///   are kept verbatim — `facetValues` is a UI list, and a value that no longer exists in this
///   library simply matches nothing. The slot itself stays, so the user can see it and change it.
///
/// Restoring is *not* done here: `CatalogSession.open` hands the decoded filter to `applyFilter`,
/// the same door a click uses, so a restored filter can never mean something a clicked one does not.
public enum FilterPersistence {

    /// Bumped only for an incompatible shape. A blob of another version is ignored (not migrated,
    /// not guessed at) — the next click overwrites it.
    public static let currentVersion = 1

    /// `v1` is in the key so a future schema writes beside the old blob instead of over it.
    public static let keyPrefix = "photons.filter.v1."

    /// 0.5 s: a value checklist or a ⌘-drag on the bar fires a change per tick, and each one would
    /// otherwise be a defaults write (and a `cfprefsd` round trip) of its own.
    public static let defaultWriteThrottle: TimeInterval = 0.5

    // MARK: the stored shape

    /// One slot as it goes over the wire: the dimension's `rawValue` plus the ticked values.
    public struct StoredSlot: Codable, Equatable, Sendable {
        public var dimension: String
        public var values: [String]

        public init(dimension: String, values: [String] = []) {
            self.dimension = dimension
            self.values = values
        }
    }

    /// The whole remembered filter. `values` empty means "the slot is here and constrains nothing"
    /// (「全部」), which is not the same as the slot being absent.
    public struct StoredFilter: Codable, Equatable, Sendable {
        public var version: Int
        public var slots: [StoredSlot]

        public init(version: Int = FilterPersistence.currentVersion, slots: [StoredSlot]) {
            self.version = version
            self.slots = slots
        }
    }

    // MARK: the key

    /// `photons.filter.v1.<first 16 hex digits of SHA-256(path)>`.
    ///
    /// The path is normalised first (tilde, `.`/`..`, trailing slash, symlinks) so `/tmp/lib`,
    /// `/private/tmp/lib/` and `~/lib` cannot become three archives for one library.
    public static func storageKey(libraryPath: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedPath(libraryPath).utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return keyPrefix + String(hex.prefix(16))
    }

    /// One spelling per library. Symlinks are resolved on purpose: `/tmp/x` and `/private/tmp/x` are
    /// the same library to the user, and it would be absurd for it to remember two different filters.
    static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: store (injectable so a test can isolate and count)

    /// The slice of `UserDefaults` this file needs. Narrow on purpose: a test substitutes a counting
    /// dictionary, and no other code path can reach into the domain through it.
    public protocol Store: AnyObject {
        func storedFilterJSON(forKey key: String) -> String?
        func storeFilterJSON(_ json: String, forKey key: String)
        func removeFilterJSON(forKey key: String)
    }

    // MARK: read / write

    /// The raw blob for `libraryPath`, or nil when there is none (or it is not readable JSON).
    public static func load(libraryPath: String, from store: Store = UserDefaults.standard) -> StoredFilter? {
        guard let json = store.storedFilterJSON(forKey: storageKey(libraryPath: libraryPath)),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StoredFilter.self, from: data)
    }

    /// `CatalogFilter` → blob. Slots keep their order: slot 1 is the leftmost popup.
    public static func stored(from filter: CatalogFilter) -> StoredFilter {
        StoredFilter(version: currentVersion,
                     slots: filter.slots.map {
                         StoredSlot(dimension: $0.dimension.rawValue, values: $0.values)
                     })
    }

    /// Blob → `CatalogFilter`, degrading exactly as the doc at the top of this file describes.
    /// `nil` means "nothing usable is stored", i.e. the caller should leave the default bar alone.
    public static func filter(from stored: StoredFilter?) -> CatalogFilter? {
        guard let stored else { return nil }
        guard stored.version == currentVersion else { return nil }

        var slots: [FilterSlot] = []
        var seen: Set<FilterDimension> = []
        for candidate in stored.slots {
            // ① a dimension this build does not know: drop the slot, do not guess a near match.
            guard let dimension = FilterDimension(rawValue: candidate.dimension) else { continue }
            // ③ same dimension twice → the first one wins (one dimension, one slot — the UI rule).
            guard !seen.contains(dimension) else { continue }
            // ③ more slots than the bar can hold → the first five, in stored order.
            guard slots.count < CatalogFilter.slotCapacity else { break }
            seen.insert(dimension)
            // ② values verbatim: no existence check, and the slot survives even if every value is
            // gone from this library.
            slots.append(FilterSlot(dimension: dimension, values: candidate.values))
        }
        guard !slots.isEmpty else { return nil }
        return CatalogFilter(slots: slots)
    }

    /// Persist `filter` for one library. Returns whether anything was written — an unchanged blob is
    /// not rewritten, which is what keeps a restore from bouncing straight back into a save.
    @discardableResult
    public static func save(_ filter: CatalogFilter, libraryPath: String,
                            to store: Store = UserDefaults.standard) -> Bool {
        guard let json = encoded(stored(from: filter)) else { return false }
        let key = storageKey(libraryPath: libraryPath)
        guard store.storedFilterJSON(forKey: key) != json else { return false }
        store.storeFilterJSON(json, forKey: key)
        return true
    }

    /// 「清除全部」 for one library. Only that key goes; every other library keeps its archive.
    public static func clear(libraryPath: String, in store: Store = UserDefaults.standard) {
        store.removeFilterJSON(forKey: storageKey(libraryPath: libraryPath))
    }

    /// Deterministic bytes (sorted keys) so "same filter" is a string comparison: that is the dedupe
    /// in `save`, and it is also what a test reads to check the shape.
    static func encoded(_ stored: StoredFilter) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: throttled writer

    /// The write side `CatalogSession` owns: throttle + coalesce, one instance per session.
    ///
    /// Main-thread only (its owner, `CatalogSession`, is `@MainActor`), so the trailing write can
    /// touch the store without hopping queues and the tests can pump the run loop and see it land.
    ///
    /// Shape of a burst: the **first** change writes immediately (a quit half a second later must not
    /// lose it), then everything that lands inside the throttle window is carried by one trailing
    /// write. Ten changes in a burst therefore cost two writes, not ten; an idle change costs one.
    public final class Writer {

        private let store: Store
        private let throttle: TimeInterval

        private var pending: DispatchWorkItem?
        private var pendingFilter: CatalogFilter?
        private var pendingPath: String?

        /// How many times this writer actually wrote the store. Cheap proof for a test (and for the
        /// throttle's own acceptance) that dedupe and coalescing did their job.
        public private(set) var writeCount = 0

        /// Quitting inside the throttle window must not swallow the last tick, which is exactly what
        /// a pending trailing write would do. A session's `flushPendingFilterSave()` is for callers
        /// that want to force it; this observer is so the app does not have to remember to.
        private var terminateToken: NSObjectProtocol?

        public init(store: Store = UserDefaults.standard,
                    throttle: TimeInterval = FilterPersistence.defaultWriteThrottle) {
            self.store = store
            self.throttle = throttle
            terminateToken = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.flush() }
        }

        deinit {
            if let terminateToken { NotificationCenter.default.removeObserver(terminateToken) }
        }

        /// The stored filter for a library, already degraded — or nil when nothing is stored.
        public func recall(libraryPath: String) -> CatalogFilter? {
            FilterPersistence.filter(from: FilterPersistence.load(libraryPath: libraryPath, from: store))
        }

        /// Remember `filter` for `libraryPath`. Safe to call on every change: unchanged blobs are
        /// skipped, and changes inside the window coalesce.
        public func remember(_ filter: CatalogFilter, libraryPath: String) {
            pendingFilter = filter
            pendingPath = libraryPath
            guard pending == nil else { return }   // the armed trailing write will carry this one
            writePending()
            arm()
        }

        /// Write what is pending **now** — what an app termination hook and a test call.
        public func flush() {
            pending?.cancel()
            pending = nil
            writePending()
        }

        /// Drop one library's archive (「清除全部」), including anything pending for it.
        public func forget(libraryPath: String) {
            if pendingPath == libraryPath {
                pending?.cancel()
                pending = nil
                pendingFilter = nil
            }
            FilterPersistence.clear(libraryPath: libraryPath, in: store)
        }

        private func arm() {
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pending = nil
                self.writePending()
            }
            pending = item
            DispatchQueue.main.asyncAfter(deadline: .now() + throttle, execute: item)
        }

        private func writePending() {
            guard let filter = pendingFilter, let path = pendingPath else { return }
            if FilterPersistence.save(filter, libraryPath: path, to: store) { writeCount += 1 }
        }
    }
}

/// `UserDefaults` is the production store; the three methods are a thin rename so the protocol can be
/// narrow without colliding with `string(forKey:)` / `set(_:forKey:)` / `removeObject(forKey:)`.
extension UserDefaults: FilterPersistence.Store {
    public func storedFilterJSON(forKey key: String) -> String? { string(forKey: key) }

    public func storeFilterJSON(_ json: String, forKey key: String) { set(json, forKey: key) }

    public func removeFilterJSON(forKey key: String) { removeObject(forKey: key) }
}
