import Foundation

public extension Notification.Name {
    static let photonsPreviewCacheCleared = Notification.Name("photons.previewCacheCleared")
}

/// Coordinates cache publication with deletion, including work already decoding on another queue.
/// Catalogs, originals and other caches are never part of this store.
public enum PreviewCacheStorage {
    private final class State: @unchecked Sendable {
        let lock = NSRecursiveLock()
        private let epochLock = NSLock()
        private var epoch: UInt64 = 0
        // Main-thread memory lookups must not wait for a large disk deletion.
        var generation: UInt64 { epochLock.lock(); defer { epochLock.unlock() }; return epoch }
        func advance() { epochLock.lock(); epoch &+= 1; epochLock.unlock() }
    }
    private static let registryLock = NSLock()
    private static var states: [String: State] = [:]
    private static func state(_ directory: URL) -> State {
        registryLock.lock(); defer { registryLock.unlock() }
        let key = directory.standardizedFileURL.path
        if let state = states[key] { return state }
        let state = State(); states[key] = state; return state
    }

    public static func generation(in directory: URL) -> UInt64 {
        state(directory).generation
    }

    @discardableResult
    public static func publish<T>(in directory: URL, generation: UInt64?, _ operation: () throws -> T) rethrows -> T? {
        let state = state(directory)
        state.lock.lock(); defer { state.lock.unlock() }
        guard generation == nil || generation == state.generation else { return nil }
        return try operation()
    }

    public struct Usage: Identifiable, Sendable {
        public let directory: URL
        public let bytes: Int64
        public let fileCount: Int
        public var id: String { directory.path }
    }

    private static let families = ["thumbs", "histograms-v1"]
    private static let payloadExtensions: Set<String> = ["jpg", "jpeg", "heic", "png", "plist"]

    /// Do not follow symlinks, and retain migration/version markers so a later launch does not
    /// mistake a freshly regenerated cache for an old layout.
    private static func files(in directory: URL) throws -> [URL] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { return [] }
        var files: [URL] = []
        var failure: Error?
        for family in families {
            let root = directory.appendingPathComponent(family, isDirectory: true)
            guard fm.fileExists(atPath: root.path),
                  try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { continue }
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if values.isRegularFile == true && payloadExtensions.contains(file.pathExtension.lowercased()) { files.append(file) }
            }
        }
        if let failure { throw failure }
        return files
    }

    public static func usage(in directory: URL) throws -> Usage {
        try publish(in: directory, generation: nil) {
            let files = try files(in: directory)
            let bytes = try files.reduce(Int64(0)) { total, file in
                let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey])
                return total + Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
            return Usage(directory: directory, bytes: bytes, fileCount: files.count)
        }!
    }

    public static func inventory(base: URL = LibraryLayout.cacheBaseDirectory, includingEmpty: Bool = false) throws -> [Usage] {
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                                          options: [.skipsHiddenFiles]).compactMap { directory in
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let usage = try usage(in: directory)
            guard includingEmpty || usage.fileCount > 0 else { return nil }
            return families.contains { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) } ? usage : nil
        }.sorted { $0.bytes == $1.bytes ? $0.directory.path < $1.directory.path : $0.bytes > $1.bytes }
    }

    public static func clear(in directory: URL) throws {
        let state = state(directory)
        state.lock.lock()
        state.advance()
        defer {
            state.lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .photonsPreviewCacheCleared, object: directory)
            }
        }
        for file in try files(in: directory) { try FileManager.default.removeItem(at: file) }
    }
}
