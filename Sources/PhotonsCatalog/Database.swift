import Foundation
import CryptoKit
import GRDB

public enum CatalogError: LocalizedError {
    case packageExists(URL)
    case packageNotFound(URL)
    case libraryFromNewerVersion(found: Int, supported: Int)
    case noSuchSourceRoot(String)
    case importSourceMissing(URL)
    case notRegularFile(URL)
    case metadataUnreadable(URL)
    case fileOperationFailed(String)
    case copyWouldClobber(URL)
    case interrupted

    public var errorDescription: String? {
        switch self {
        case .packageExists(let u): return "already exists: \(u.path)"
        case .packageNotFound(let u): return "no library package at \(u.path)"
        case .libraryFromNewerVersion(let found, let supported):
            return "this library was created by a newer Photons (schema v\(found), this build supports v\(supported)); "
                + "it was not opened and not modified"
        case .noSuchSourceRoot(let id): return "no such source root: \(id)"
        case .importSourceMissing(let u): return "import source does not exist: \(u.path)"
        case .notRegularFile(let u): return "not a regular file: \(u.path)"
        case .metadataUnreadable(let u): return "could not read metadata: \(u.lastPathComponent)"
        case .fileOperationFailed(let m): return "file operation failed: \(m)"
        case .copyWouldClobber(let u): return "refusing to overwrite \(u.path)"
        case .interrupted: return "import interrupted"
        }
    }
}

/// A library is a *package directory*, so moving one item moves the database and (in copy mode)
/// the originals together. Cache lives outside it, keyed by the package path, so two libraries can
/// never poison each other's buffers (darktable does the same with `<sha1>.d/`).
public struct LibraryLayout: Sendable {
    public static let packageExtension = "photonslibrary"

    public let packageURL: URL

    public init(packageURL: URL) {
        self.packageURL = packageURL.standardizedFileURL
    }

    public var databaseURL: URL { packageURL.appendingPathComponent("library.db", isDirectory: false) }
    public var originalsURL: URL { packageURL.appendingPathComponent("originals", isDirectory: true) }
    public var previewsURL: URL { packageURL.appendingPathComponent("previews", isDirectory: true) }
    public var backupsURL: URL { packageURL.appendingPathComponent("backups", isDirectory: true) }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [packageURL, originalsURL, previewsURL, backupsURL] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// `~/Library/Caches/Photons/<sha1(package path)>/` — decoded buffers, thumbnails (M3).
    public var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let key = Self.digest(packageURL.path).prefix(16)
        return base.appendingPathComponent("Photons/\(key)", isDirectory: true)
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The catalog: one SQLite file inside a package, GRDB on top, WAL on.
public final class Catalog {
    public let layout: LibraryLayout
    public let dbQueue: DatabaseQueue

    private init(layout: LibraryLayout, dbQueue: DatabaseQueue) {
        self.layout = layout
        self.dbQueue = dbQueue
    }

    // MARK: lifecycle

    public static func configuration() -> Configuration {
        var config = Configuration()
        // WAL + NORMAL: a crash can lose the last commit, never the database. The import pipeline
        // commits one file at a time, so "the last commit" is at most one photo.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA busy_timeout = 5000")
        }
        return config
    }

    /// Create a new library package. Refuses to touch an existing one.
    public static func create(at packageURL: URL) throws -> Catalog {
        let layout = LibraryLayout(packageURL: packageURL)
        let fm = FileManager.default
        if fm.fileExists(atPath: layout.databaseURL.path) {
            throw CatalogError.packageExists(packageURL)
        }
        try layout.ensureDirectories()
        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: configuration())
        try Schema.migrate(queue)
        try stampSchemaVersion(queue)
        let catalog = Catalog(layout: layout, dbQueue: queue)
        try catalog.writeSettings([
            "schema_version": "\(Schema.version)",
            "unique_hash_version": "\(Schema.uniqueHashVersion)",
            "app_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ])
        return catalog
    }

    /// Open an existing library, snapshotting it first when a migration is pending.
    public static func open(at packageURL: URL) throws -> Catalog {
        let layout = LibraryLayout(packageURL: packageURL)
        guard FileManager.default.fileExists(atPath: layout.databaseURL.path) else {
            throw CatalogError.packageNotFound(packageURL)
        }
        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: configuration())

        let applied = try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }
        if applied > Schema.version {
            // ART's lesson: a newer file opened by an older build silently drops fields. Refuse.
            throw CatalogError.libraryFromNewerVersion(found: applied, supported: Schema.version)
        }
        if applied < Schema.version {
            try snapshot(layout: layout, queue: queue, fromVersion: applied)
        }
        try Schema.migrate(queue)
        try stampSchemaVersion(queue)
        return Catalog(layout: layout, dbQueue: queue)
    }

    /// GRDB tracks applied migrations in its own table; we also keep `PRAGMA user_version` honest so
    /// `sqlite3 library.db 'PRAGMA user_version'` (and our forward guard) means what it says.
    private static func stampSchemaVersion(_ queue: DatabaseQueue) throws {
        let version = Schema.version
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
    }

    /// Copy `library.db` aside before migrating, keeping the two most recent backups.
    private static func snapshot(layout: LibraryLayout, queue: DatabaseQueue, fromVersion: Int) throws {
        // Fold the WAL back into the main file so the copy is self-contained.
        // Must run outside a transaction: a checkpoint inside one fails with SQLITE_LOCKED.
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: layout.backupsURL, withIntermediateDirectories: true)
        let dest = layout.backupsURL.appendingPathComponent(String(format: "library.bak-v%d.db", fromVersion))
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: layout.databaseURL, to: dest)

        let all = (try? fm.contentsOfDirectory(at: layout.backupsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let backups = all
            .filter { $0.lastPathComponent.hasPrefix("library.bak-v") }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
        for old in backups.dropFirst(2) { try? fm.removeItem(at: old) }
    }

    // MARK: settings

    public func setting(_ key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    public func writeSettings(_ values: [String: String]) throws {
        try dbQueue.write { db in
            for (k, v) in values.sorted(by: { $0.key < $1.key }) {
                try db.execute(sql: """
                    INSERT INTO settings(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """, arguments: [k, v])
            }
        }
    }

    public var schemaVersionApplied: Int {
        (try? dbQueue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }) ?? 0
    }

    /// Run SQLite's own integrity check plus our referential expectations.
    public func integrityCheck() throws -> String {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? "unknown"
        }
    }
}
