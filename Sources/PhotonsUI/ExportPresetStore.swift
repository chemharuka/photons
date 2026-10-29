import Foundation
import Observation
import PhotonsExport

// MARK: - export presets on disk (099)
//
// One preset per file under `~/Library/Application Support/Photons/export-presets/`. The file name
// is the preset name made URL-safe, so a user can back the folder up, sync it, or drop a preset in
// by hand and still see it in the sheet's popup.
@MainActor
@Observable
public final class ExportPresetStore {

    public let directory: URL
    public private(set) var names: [String] = []
    public private(set) var lastError: String?

    public init(directory: URL = ExportPresetStore.defaultDirectory) {
        self.directory = directory
        refresh()
    }

    public nonisolated static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Photons/export-presets", isDirectory: true)
    }

    public func refresh() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                                                                    includingPropertiesForKeys: nil)
            names = files.filter { $0.pathExtension.lowercased() == "json" }
                .map { file in
                    // The popup shows the preset's own label; the file name stays URL-safe.
                    if let preset = try? ExportPreset.load(from: file),
                       let name = preset.name, !name.isEmpty {
                        return name
                    }
                    return file.deletingPathExtension().lastPathComponent
                }
                .sorted()
            lastError = nil
        } catch {
            names = []
            lastError = error.localizedDescription
        }
    }

    public func url(for name: String) -> URL {
        directory.appendingPathComponent(Self.safeFilename(name)).appendingPathExtension("json")
    }

    @discardableResult
    public func save(_ preset: ExportPreset, named name: String) throws -> ExportPreset {
        var copy = preset
        copy.name = name
        try copy.save(to: url(for: name))
        refresh()
        return copy
    }

    public func load(named name: String) throws -> ExportPreset {
        try ExportPreset.load(from: url(for: name))
    }

    public func delete(named name: String) throws {
        let file = url(for: name)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        refresh()
    }

    /// A filename, not a path: separators and the characters macOS/Windows disagree about become
    /// `-`, whitespace too, and an empty name falls back to `preset`.
    public static func safeFilename(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|%\0")
        var out = ""
        for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
            if bad.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                out.append("-")
            } else {
                out.append(Character(scalar))
            }
        }
        while out.hasPrefix(".") { out.removeFirst() }
        return out.isEmpty ? "preset" : out
    }
}
