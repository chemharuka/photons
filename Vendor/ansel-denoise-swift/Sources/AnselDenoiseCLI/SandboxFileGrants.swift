// GPL-3.0-or-later. Foundation file-grant transport for the independent CLI.
import Foundation

final class SandboxFileGrants {
    private var active: [URL] = []
    init() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_HELPER_BOOKMARKS"] else { return }
        let manifest = URL(fileURLWithPath: path)
        let values = try JSONDecoder().decode([String].self, from: Data(contentsOf: manifest))
        for value in values {
            guard let bookmark = Data(base64Encoded: value) else { throw CocoaError(.fileReadCorruptFile) }
            var stale = false
            // Ordinary bookmarks passed by the parent carry its dynamic file grants. They are
            // deliberately not app-scoped bookmarks tied to the main executable's identity.
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            if url.startAccessingSecurityScopedResource() { active.append(url) }
        }
    }
    deinit { for url in active { url.stopAccessingSecurityScopedResource() } }
}
