import Foundation
import GRDB

// MARK: - enums (stored as their raw strings, so the file stays greppable)

public enum ManagementMode: String, Codable, Sendable, CaseIterable {
    case reference
    case copy
}

public enum RootStatus: String, Codable, Sendable {
    case online
    case offline
}

public enum AssetKind: String, Codable, Sendable {
    case raw
    case jpeg
    case heic

    public static func detect(_ ext: String) -> AssetKind? {
        switch ext.lowercased() {
        case "dng", "cr3", "cr2", "nef", "arw", "raf", "rw2", "orf", "rwl", "pef", "srw", "x3f",
             "iiq", "mos", "mrw", "3fr", "erf", "kdc", "dcr", "srf", "raw":
            return .raw
        case "jpg", "jpeg":
            return .jpeg
        case "heic", "heif":
            return .heic
        default:
            return nil
        }
    }
}

public enum ImportOutcome: String, Codable, Sendable {
    case added
    case duplicate
    case unchanged
    case failed
    /// Same bytes as an existing asset, but that asset's file was gone — the file moved.
    case moved
    /// Seen, deliberately not imported (an `.xmp` sidecar, an AAE sidecar, …).
    case ignored
}

public enum ImportState: String, Codable, Sendable {
    case running
    case finished
    case failed
}

// MARK: - records

/// Common column-name conversion so the SQL stays snake_case and Swift stays camelCase.
public protocol CatalogRecord: Codable, FetchableRecord, PersistableRecord {}

extension CatalogRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
}

public struct SourceRoot: CatalogRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "source_roots"

    public var id: String
    public var volumeUuid: String?
    public var bookmark: Data?
    public var displayName: String
    public var pathHint: String
    public var managementMode: ManagementMode
    public var status: RootStatus
    public var createdAt: String

    public init(id: String = UUID().uuidString,
                volumeUuid: String? = nil,
                bookmark: Data? = nil,
                displayName: String,
                pathHint: String,
                managementMode: ManagementMode,
                status: RootStatus = .online,
                createdAt: String = ISO8601.now()) {
        self.id = id
        self.volumeUuid = volumeUuid
        self.bookmark = bookmark
        self.displayName = displayName
        self.pathHint = pathHint
        self.managementMode = managementMode
        self.status = status
        self.createdAt = createdAt
    }
}

public struct Asset: CatalogRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "assets"

    public var id: String
    public var sourceRootId: String
    public var relPath: String
    public var filename: String
    public var ext: String
    public var kind: AssetKind
    public var size: Int
    public var mtime: Double
    public var contentHash: String
    public var quickHash: String?
    public var width: Int?
    public var height: Int?
    public var captureTime: String?
    public var captureLocalDate: String?
    public var captureTimeSource: String?
    public var rating: Int
    public var flag: String?
    public var colorLabel: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var cameraKey: String?
    public var lens: String?
    public var developJson: String
    public var developVersion: Int
    /// When `developJson` was last written (ISO8601 UTC). nil for a row that predates a real write.
    public var editTime: String?
    /// Seq in `asset_history` that is currently on screen (D10's `history_end` cursor). 0 = none.
    public var historyEnd: Int
    public var renderVersion: Int
    public var importedAt: String
    public var checkedAt: String?
    /// The original file is **not** at `relPath` under its root (v5).
    ///
    /// A cached filesystem fact, recomputed by `Catalog.refreshAvailability()` on open and rescan —
    /// never a state the app sets by hand. `true` means: the root is online, we stat'ed the path,
    /// and nothing was there. The row, its rating and its whole edit history are untouched; the
    /// user decides whether to relink it or remove it.
    public var missing: Bool
    public var deleted: Bool

    public init(id: String = UUID().uuidString,
                sourceRootId: String,
                relPath: String,
                filename: String,
                ext: String,
                kind: AssetKind,
                size: Int,
                mtime: Double,
                contentHash: String,
                quickHash: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                captureTime: String? = nil,
                captureLocalDate: String? = nil,
                captureTimeSource: String? = nil,
                rating: Int = 0,
                flag: String? = nil,
                colorLabel: String? = nil,
                cameraMake: String? = nil,
                cameraModel: String? = nil,
                cameraKey: String? = nil,
                lens: String? = nil,
                developJson: String = "{}",
                developVersion: Int = 1,
                editTime: String? = nil,
                historyEnd: Int = 0,
                renderVersion: Int = 1,
                importedAt: String = ISO8601.now(),
                checkedAt: String? = nil,
                missing: Bool = false,
                deleted: Bool = false) {
        self.id = id
        self.sourceRootId = sourceRootId
        self.relPath = relPath
        self.filename = filename
        self.ext = ext
        self.kind = kind
        self.size = size
        self.mtime = mtime
        self.contentHash = contentHash
        self.quickHash = quickHash
        self.width = width
        self.height = height
        self.captureTime = captureTime
        self.captureLocalDate = captureLocalDate
        self.captureTimeSource = captureTimeSource
        self.rating = rating
        self.flag = flag
        self.colorLabel = colorLabel
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.cameraKey = cameraKey
        self.lens = lens
        self.developJson = developJson
        self.developVersion = developVersion
        self.editTime = editTime
        self.historyEnd = historyEnd
        self.renderVersion = renderVersion
        self.importedAt = importedAt
        self.checkedAt = checkedAt
        self.missing = missing
        self.deleted = deleted
    }

    /// Readable form of `missing` for call sites that talk about the user's situation rather than
    /// the column: "the original file moved away".
    public var isMissing: Bool { missing }

    /// `lower(make|model)` — the filter key. Normalised once at import so queries stay dumb.
    public static func cameraKey(make: String?, model: String?) -> String? {
        // Collapse internal whitespace too: EXIF strings arrive as "LEICA  SL3 " often enough that
        // a filter key built from a single space would silently miss half the library.
        func normalise(_ s: String?) -> String {
            (s ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let m = normalise(make)
        let d = normalise(model)
        guard !(m.isEmpty && d.isEmpty) else { return nil }
        let raw = d.isEmpty ? m : (m.isEmpty ? d : "\(m)|\(d)")
        return raw.lowercased()
    }
}

public struct AssetMetadata: CatalogRecord, Equatable, Sendable {
    public static let databaseTableName = "asset_metadata"

    public var assetId: String
    public var exifJson: String
    public var xmpBlob: String?
    public var iso: Int?
    public var focalLength: Double?
    public var aperture: Double?
    public var shutter: String?
    public var orientation: Int?

    public init(assetId: String, exifJson: String = "{}", xmpBlob: String? = nil,
                iso: Int? = nil, focalLength: Double? = nil, aperture: Double? = nil,
                shutter: String? = nil, orientation: Int? = nil) {
        self.assetId = assetId
        self.exifJson = exifJson
        self.xmpBlob = xmpBlob
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutter = shutter
        self.orientation = orientation
    }
}

public struct AssetHistory: CatalogRecord, Equatable, Sendable {
    public static let databaseTableName = "asset_history"

    public var assetId: String
    public var seq: Int
    public var developJson: String
    public var label: String?
    public var createdAt: String
}

public struct Keyword: CatalogRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "keywords"
    public var id: String
    public var name: String
    public var parentId: String?
}

public struct Album: CatalogRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "albums"
    public var id: String
    public var parentId: String?
    public var name: String
    public var sort: Int
    public var createdAt: String
}

public struct ImportSession: CatalogRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "import_sessions"

    public var id: String
    public var sourceRootId: String?
    public var mode: ManagementMode
    public var state: ImportState
    public var totalCount: Int
    public var importedCount: Int
    public var skippedCount: Int
    public var failedCount: Int
    public var startedAt: String
    public var finishedAt: String?
    public var errorMessage: String?
}

public struct ImportFile: CatalogRecord, Equatable, Sendable {
    public static let databaseTableName = "import_files"

    public var sessionId: String
    public var sourcePath: String
    public var assetId: String?
    public var outcome: ImportOutcome
    public var reason: String?
    public var seenAt: String
}

// MARK: - helpers

public enum ISO8601 {
    private static let lock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public static func now() -> String { string(from: Date()) }

    public static func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: string)
    }
}
