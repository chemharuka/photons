import Foundation

/// 「上次打开的库」 — the one thing the next launch has to remember.
///
/// The app has no document-based launch, so without this every launch starts on an empty window even
/// though the user opens the same library every day. Writes happen in `CatalogSession.open` (only on
/// the success path); the decision of *which* URL to open is the pure `launchURL`, kept here rather
/// than in `PhotonsApp` because an executable target cannot be imported by the test bundle.
public enum RecentLibrary {

    public static let defaultsKey = "photons.recentLibraryPath"

    /// `UserDefaults` in the app; an in-memory dictionary in tests.
    public protocol Store {
        func string(forKey key: String) -> String?
        func set(_ value: String?, forKey key: String)
    }

    public static func remember(_ url: URL, in store: Store = UserDefaults.standard) {
        store.set(url.standardizedFileURL.path, forKey: defaultsKey)
    }

    public static func recall(from store: Store = UserDefaults.standard) -> URL? {
        guard let path = store.string(forKey: defaultsKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func forget(in store: Store = UserDefaults.standard) {
        store.set(nil, forKey: defaultsKey)
    }

    /// Which library to open at launch: the command line wins; otherwise the remembered path, but
    /// only while it is still a directory. A vanished library means an empty window, not a modal
    /// error the user cannot dismiss at launch.
    public static func launchURL(explicit: String?,
                                 remembered: URL?,
                                 isDirectory: (URL) -> Bool = defaultIsDirectory) -> URL? {
        if let explicit, !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        }
        guard let remembered, isDirectory(remembered) else { return nil }
        return remembered
    }

    public static func defaultIsDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

extension UserDefaults: RecentLibrary.Store {
    /// The protocol takes a `String?` (so `nil` means "forget"); `UserDefaults` itself stores `Any?`.
    public func set(_ value: String?, forKey key: String) {
        set(value as Any?, forKey: key)
    }
}
