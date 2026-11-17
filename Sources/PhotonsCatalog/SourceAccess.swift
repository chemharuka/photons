import Foundation
import GRDB
import PhotonsFileAccess

extension Catalog {
    /// Restore permission before availability scans mark files missing. A disconnected drive or
    /// a bookmark from another signing identity keeps its database record for later reconnection.
    func restoreSourceAccess() throws {
        for var root in try roots() where root.managementMode == .reference {
            guard let data = root.bookmark, let resolved = try? FileAccessStore.resolve(data) else { continue }
            sourceAccessLock.lock()
            sourceAccess[root.id] = resolved.access
            sourceAccessLock.unlock()
            let path = resolved.access.url.standardizedFileURL.path
            if path != root.pathHint || resolved.stale {
                root.pathHint = path
                if let fresh = try? FileAccessStore.bookmark(for: resolved.access.url) { root.bookmark = fresh }
                let updated = root
                try dbQueue.write { db in try updated.update(db) }
            }
            if let bookmark = root.bookmark { FileAccessStore.shared.rememberBookmark(bookmark, for: resolved.access.url) }
        }
    }

    func retainSourceAccess(_ root: SourceRoot) {
        guard root.managementMode == .reference else { return }
        let access = root.bookmark.flatMap { try? FileAccessStore.resolve($0).access }
            ?? FileAccessStore.shared.access(to: URL(fileURLWithPath: root.pathHint))
        sourceAccessLock.lock()
        sourceAccess[root.id] = access
        sourceAccessLock.unlock()
        if let bookmark = root.bookmark { FileAccessStore.shared.rememberBookmark(bookmark, for: access.url) }
    }

    func sourceURL(for root: SourceRoot) -> URL {
        sourceAccessLock.lock(); defer { sourceAccessLock.unlock() }
        return sourceAccess[root.id]?.url ?? URL(fileURLWithPath: root.pathHint, isDirectory: true)
    }

    /// Explicit folder reselection upgrades a pre-sandbox library without reimporting its photos.
    public func authorizeSourceFolder(_ folder: URL) throws {
        try FileAccessStore.shared.rememberSelection(folder)
        let access = FileAccessStore.shared.access(to: folder)
        defer { withExtendedLifetime(access) {} }
        let path = access.url.standardizedFileURL.path
        for var root in try roots() where root.managementMode == .reference && Self.path(path, contains: root.pathHint) {
            root.bookmark = try FileAccessStore.bookmark(for: URL(fileURLWithPath: root.pathHint))
            let updated = root
            try dbQueue.write { db in try updated.update(db) }
            retainSourceAccess(root)
        }
    }
}
