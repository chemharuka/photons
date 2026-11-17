import Foundation
import Security

/// Keep this object alive for the entire operation, including background work.
/// A false `startAccessing…` is normal for files already inside the app container.
public final class FileAccess: @unchecked Sendable {
    public let url: URL
    private let scope: URL
    private let started: Bool
    private let stop: (URL) -> Void
    private let owner: FileAccess?

    init(url: URL, scope: URL, start: (URL) -> Bool, stop: @escaping (URL) -> Void) {
        self.url = url
        self.scope = scope
        self.stop = stop
        self.owner = nil
        started = start(scope)
    }

    private init(url: URL, owner: FileAccess) {
        self.url = url; self.scope = owner.url; self.owner = owner
        self.started = false; self.stop = { _ in }
    }

    func appendingTarget(_ url: URL) -> FileAccess { FileAccess(url: url, owner: self) }

    public convenience init(_ url: URL) {
        self.init(url: url, scope: url,
                  start: { $0.startAccessingSecurityScopedResource() },
                  stop: { $0.stopAccessingSecurityScopedResource() })
    }

    deinit { if started { stop(scope) } }
}

public enum SandboxEnvironment {
    public static var isSandboxed: Bool {
        #if os(iOS)
        return true
        #else
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        else { return false }
        return (value as? Bool) == true
        #endif
    }
}

/// Stores grants obtained through the system file panels. A path is never treated as permission.
/// Bookmarks belong to the signed application, so another app or a new signing identity may need
/// the user to select the same folder again. Failed resolutions are retained for offline volumes.
public final class FileAccessStore: @unchecked Sendable {
    public static let shared = FileAccessStore()
    private static let key = "photons.fileAccess.bookmarks.v1"
    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func rememberedURLs() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return (defaults.dictionary(forKey:Self.key) ?? [:]).keys.map { URL(fileURLWithPath:$0) }
    }

    public static func bookmark(for url: URL) throws -> Data {
        let access = FileAccess(url)
        return try withExtendedLifetime(access) {
            do {
                #if os(iOS)
                return try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
                #else
                return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                #endif
            } catch {
                // CLI / unsigned unit tests can still use ordinary bookmarks. A sandboxed app
                // must surface failure, rather than pretend it saved persistent permission.
                guard !SandboxEnvironment.isSandboxed else { throw error }
                return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
    }

    public func rememberSelection(_ url: URL) throws {
        let data = try Self.bookmark(for: url)
        rememberBookmark(data, for: url)
    }

    public func rememberBookmark(_ data: Data, for url: URL) {
        lock.lock(); defer { lock.unlock() }
        var records = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        records[url.standardizedFileURL.path] = data
        defaults.set(records, forKey: Self.key)
    }

    public static func resolve(_ bookmark: Data) throws -> (access: FileAccess, stale: Bool) {
        var stale = false
        #if os(iOS)
        let options: URL.BookmarkResolutionOptions = [.withoutUI]
        #else
        let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: options,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (FileAccess(url), stale)
    }

    public func access(to url: URL) -> FileAccess {
        lock.lock()
        let records = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        lock.unlock()
        let path = url.standardizedFileURL.path
        // Prefer the narrowest selected directory; checking components avoids /Photos2 matching /Photos.
        for key in records.keys.filter({ Self.contains($0, path) }).sorted(by: { $0.count > $1.count }) {
            guard let data = records[key], let resolved = try? Self.resolve(data) else { continue }
            let base = resolved.access.url
            let target = path == key ? base : base.appendingPathComponent(String(path.dropFirst(key == "/" ? 1 : key.count + 1)))
            if resolved.stale, let fresh = try? Self.bookmark(for: base) {
                lock.lock()
                var current = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
                current[key] = fresh
                current[base.standardizedFileURL.path] = fresh
                defaults.set(current, forKey: Self.key)
                lock.unlock()
            }
            // Transfer the scope lifetime to a child-path access object without starting it twice.
            return resolved.access.appendingTarget(target)
        }
        return FileAccess(url)
    }

    static func contains(_ parent: String, _ child: String) -> Bool {
        parent == child || (parent == "/" ? child.hasPrefix("/") : child.hasPrefix(parent + "/"))
    }
}
