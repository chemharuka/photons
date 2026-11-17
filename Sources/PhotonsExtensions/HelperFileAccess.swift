import Foundation
import PhotonsFileAccess

/// PowerBox grants are dynamic and aren't part of a helper's inherited entitlements.
/// Transfer Foundation bookmarks, not image copies, so a 200 MB RAW stays in place.
final class HelperFileAccess {
    static let environmentKey = "PHOTONS_HELPER_BOOKMARKS"
    let manifest: URL
    private var access: [FileAccess] = []

    init(arguments: [String]) throws {
        manifest = FileManager.default.temporaryDirectory.appendingPathComponent("photons-grants-\(UUID().uuidString).json")
        var bookmarks: [String] = []
        var seen = Set<String>()
        for path in arguments where path.hasPrefix("/") {
            var url = URL(fileURLWithPath: path)
            // A not-yet-created output is authorized through its selected containing directory.
            if !FileManager.default.fileExists(atPath: url.path) { url.deleteLastPathComponent() }
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            let lease = FileAccessStore.shared.access(to: url)
            access.append(lease)
            let data = try lease.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            bookmarks.append(data.base64EncodedString())
        }
        let data = try JSONEncoder().encode(bookmarks)
        guard FileManager.default.createFile(atPath: manifest.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    deinit { try? FileManager.default.removeItem(at: manifest) }
}
