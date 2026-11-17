import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsLocalization

@MainActor
final class PreviewCacheSettingsModel: ObservableObject {
    @Published var entries: [PreviewCacheStorage.Usage] = []
    @Published var busy = false
    @Published var error: String?
    var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    var count: Int { entries.reduce(0) { $0 + $1.fileCount } }

    func refresh() { perform {} }
    func clearAll() {
        perform {
            for entry in try PreviewCacheStorage.inventory(includingEmpty: true) {
                try PreviewCacheStorage.clear(in: entry.directory)
            }
        }
    }
    func clear(_ directories: [URL]) {
        perform { for directory in directories { try PreviewCacheStorage.clear(in: directory) } }
    }
    private func perform(_ work: @escaping @Sendable () throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try work(); return try PreviewCacheStorage.inventory() }
            DispatchQueue.main.async {
                self.busy = false
                switch result {
                case .success(let entries): self.entries = entries
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
}

struct PreviewCacheSettingsView: View {
    @StateObject private var model = PreviewCacheSettingsModel()
    @State private var libraries = LibraryHistory.entries()
    private var root: URL { LibraryLayout.cacheBaseDirectory }

    private func libraryName(_ usage: PreviewCacheStorage.Usage) -> String {
        libraries.first { LibraryLayout(packageURL: $0.url).cacheDirectory.standardizedFileURL.path == usage.directory.standardizedFileURL.path }?
            .url.deletingPathExtension().lastPathComponent ?? usage.directory.lastPathComponent
    }
    private func size(_ bytes: Int64) -> String {
        bytes == 0 ? "0 KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("cache.location")).font(.headline)
                Text(root.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.tr("cache.reveal")) {
                    do {
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    } catch { model.error = error.localizedDescription }
                }.accessibilityIdentifier("settings.cache.reveal")
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(size(model.bytes)).font(.system(size: 23, weight: .semibold))
                    Text(L10n.tr("cache.fileCount", String(model.count))).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(L10n.tr("cache.refresh")) { model.refresh() }.disabled(model.busy)
                    .accessibilityIdentifier("settings.cache.refresh")
                Button(L10n.tr("cache.clearAll")) { model.clearAll() }
                    .disabled(model.busy || model.entries.isEmpty)
                    .accessibilityIdentifier("settings.cache.clearAll")
            }
            Text(L10n.tr("cache.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            ForEach(model.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(libraryName(entry)).lineLimit(1).truncationMode(.middle)
                        Text(size(entry.bytes)).font(.caption).foregroundStyle(.secondary)
                    }.help(entry.directory.path)
                    Spacer()
                    Button(L10n.tr("cache.clear")) { model.clear([entry.directory]) }.disabled(model.busy)
                }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: LibraryHistory.changed)) { _ in libraries = LibraryHistory.entries() }
    }
}
