import Foundation
import PhotonsExport

// MARK: - the last export draft (161 §5)
//
// 「导出格式要有记忆，下次导出按上次选择的来」 — the whole draft, not just the format. The draft is a
// **view preference**, like the filter bar's slots: it never enters the catalog, history or a
// document. So it lives in `UserDefaults`, one versioned JSON blob, and the store is injected so a
// test can count/isolate writes instead of touching the real domain.
//
// Two things this file deliberately does **not** own:
//
//   · the named presets in `ExportPresetStore` — those are files the user saves/names/deletes; a
//     field edited after loading a named preset changes only this draft and never writes back into
//     the preset file. The two lists coexist and cannot overwrite each other.
//   · when to write — the model saves after a successful export and on close (see
//     `ExportSheetModel.saveDraftOnClose`), never on every slider tick.
public enum ExportDraftPersistence {

    /// Bumped only when the stored shape is incompatible. A blob from another version is treated as
    /// unreadable (ignored + removed), never migrated by guesswork.
    public static let currentVersion = 1

    /// Versioned key so a future schema writes beside this blob instead of over it.
    public static let storageKey = "photons.export.draft.v1"

    // MARK: shape

    /// The whole remembered draft. The directory is stored as a path because `UserDefaults`/JSON have
    /// no URL type; a path that no longer exists is still a fine starting point for the next export.
    public struct Draft: Codable, Equatable, Sendable {
        public var version: Int
        public var preset: ExportPreset
        public var outputDirectory: String

        public init(version: Int = ExportDraftPersistence.currentVersion,
                    preset: ExportPreset, outputDirectory: URL) {
            self.version = version
            self.preset = preset
            self.outputDirectory = outputDirectory.path
        }

        public var directoryURL: URL { URL(fileURLWithPath: outputDirectory, isDirectory: true) }
    }

    /// What reading the store found. `missing` and `unreadable` both mean "use the defaults", but
    /// only `unreadable` is worth telling the user about (and clearing).
    public enum Recall: Equatable {
        case missing
        case draft(Draft)
        case unreadable
    }

    // MARK: store (injectable so a test can isolate and count)

    /// The slice of `UserDefaults` this file needs. Narrow on purpose: a test substitutes an
    /// in-memory dictionary and no other code path can reach into the domain through it.
    public protocol Store: AnyObject {
        func exportDraftData(forKey key: String) -> Data?
        func setExportDraftData(_ data: Data?, forKey key: String)
    }

    // MARK: read / write

    public static func recall(from store: Store = UserDefaults.standard,
                              key: String = storageKey) -> Recall {
        guard let data = store.exportDraftData(forKey: key) else { return .missing }
        guard let draft = try? JSONDecoder().decode(Draft.self, from: data),
              draft.version == currentVersion else { return .unreadable }
        return .draft(draft)
    }

    /// Persist the draft. Returns whether bytes were written; an unchanged blob is skipped (the same
    /// trick `FilterPersistence.save` uses), so "save on close" cannot bounce back into another write.
    @discardableResult
    public static func save(preset: ExportPreset, outputDirectory: URL,
                            to store: Store = UserDefaults.standard,
                            key: String = storageKey) -> Bool {
        let draft = Draft(preset: preset, outputDirectory: outputDirectory)
        guard let data = encoded(draft) else { return false }
        guard store.exportDraftData(forKey: key) != data else { return false }
        store.setExportDraftData(data, forKey: key)
        return true
    }

    public static func clear(in store: Store = UserDefaults.standard,
                             key: String = storageKey) {
        store.setExportDraftData(nil, forKey: key)
    }

    /// Deterministic bytes (sorted keys) so dedupe is a byte comparison and a test can read the shape.
    static func encoded(_ draft: Draft) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(draft)
    }
}

/// `UserDefaults` is the production store; the two methods are a thin rename so the protocol can stay
/// narrow without colliding with `data(forKey:)` / `set(_:forKey:)`.
extension UserDefaults: ExportDraftPersistence.Store {
    public func exportDraftData(forKey key: String) -> Data? { data(forKey: key) }

    public func setExportDraftData(_ data: Data?, forKey key: String) {
        if let data { set(data, forKey: key) } else { removeObject(forKey: key) }
    }
}
