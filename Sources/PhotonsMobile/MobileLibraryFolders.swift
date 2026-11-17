#if os(iOS)
import PhotonsLocalization
import Foundation
import SwiftUI

struct MobileLibraryFolder: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
}
enum MobileFolderScope: Equatable { case all, unfiled, folder(UUID) }
/// One assignment per photo, stored atomically inside the one library. Originals and edit history
/// never move when the user reorganizes folders, and removing a folder cannot remove a photograph.
struct MobileFolderIndex: Codable, Equatable, Sendable {
    var version = 1
    var folders: [MobileLibraryFolder] = []
    var assignments: [String: UUID] = [:]
    func contains(_ id: String,in scope: MobileFolderScope) -> Bool {
        switch scope {
        case .all: return true
        case .unfiled: return assignments[id] == nil
        case .folder(let folder): return assignments[id] == folder
        }
    }
    func validatedName(_ raw: String, excluding: UUID? = nil) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100, !name.contains("/"), !name.contains("\n") else {
            throw MobileError.message(L10n.tr("ipad.5b6e118424f4"))
        }
        guard !folders.contains(where: { $0.id != excluding && $0.name.compare(name,options: [.caseInsensitive,.diacriticInsensitive]) == .orderedSame }) else {
            throw MobileError.message(L10n.tr("ipad.a4a2bf24cfaa"))
        }
        return name
    }
}
extension MobileEngine {
    func folderIndex() throws -> MobileFolderIndex {
        let url = libraryURL.appendingPathComponent("MobileFolders.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let result = try JSONDecoder().decode(MobileFolderIndex.self,from: Data(contentsOf: url))
        guard result.version == 1, Set(result.folders.map(\.id)).count == result.folders.count,
              Set(result.assignments.values).isSubset(of: Set(result.folders.map(\.id))) else {
            throw MobileError.message(L10n.tr("ipad.146824e1ae93"))
        }
        return result
    }
    private func saveFolders(_ value: MobileFolderIndex) throws {
        try FileManager.default.createDirectory(at: libraryURL,withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(value).write(to: libraryURL.appendingPathComponent("MobileFolders.json"),options: .atomic)
    }
    @discardableResult func createFolder(_ name: String) throws -> MobileLibraryFolder {
        var index = try folderIndex()
        let folder = MobileLibraryFolder(name: try index.validatedName(name))
        index.folders.append(folder); try saveFolders(index); return folder
    }
    func renameFolder(_ id: UUID,to name: String) throws {
        var index = try folderIndex()
        guard let position = index.folders.firstIndex(where: { $0.id == id }) else { throw MobileError.message(L10n.tr("ipad.ccbf07f84d31")) }
        index.folders[position].name = try index.validatedName(name,excluding: id); try saveFolders(index)
    }
    func removeFolder(_ id: UUID) throws {
        var index = try folderIndex()
        index.folders.removeAll { $0.id == id }; index.assignments = index.assignments.filter { $0.value != id }
        try saveFolders(index)
    }
    func movePhotos(_ ids: Set<String>,to folder: UUID?) throws {
        var index = try folderIndex()
        guard folder == nil || index.folders.contains(where: { $0.id == folder }) else { throw MobileError.message(L10n.tr("ipad.ccbf07f84d31")) }
        let known = Set(try photos().map(\.id))
        guard ids.isSubset(of: known) else { throw MobileError.message(L10n.tr("ipad.aaa15f657632")) }
        for id in ids { index.assignments[id] = folder }
        try saveFolders(index)
    }
}

struct MobileFolderList: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var editor: MobileFolderEditor?
    @State private var removing: MobileLibraryFolder?
    var body: some View {
        VStack(alignment: .leading,spacing: 12) {
            folderButton(L10n.tr("ipad.ca22cb69bbf7"),icon: "square.grid.2x2",scope: .all)
            folderButton(L10n.tr("ipad.d64dc9ae400c"),icon: "tray",scope: .unfiled)
            ForEach(model.folders.folders) { folder in
                folderButton(folder.name,icon: "folder",scope: .folder(folder.id))
                    .contextMenu {
                        Button(L10n.tr("ipad.7249f19c9e4f")) { editor = .init(folder: folder) }
                        Button(L10n.tr("ipad.f2a987fb119b"),role: .destructive) { removing = folder }
                    }
            }
            Button(L10n.tr("ipad.cf28f49ec597"),systemImage: "folder.badge.plus") { editor = .init() }
                .accessibilityIdentifier("new-library-folder")
        }.disabled(model.busy)
        .sheet(item: $editor) { value in
            MobileFolderEditorView(model: model,folder: value.folder)
        }
        .alert(L10n.tr("ipad.2c5db903d029"),isPresented: Binding(get: { removing != nil },set: { if !$0 { removing = nil } })) {
            Button(L10n.tr("ipad.f2a987fb119b"),role: .destructive) { if let removing { model.removeFolder(removing.id) }; removing = nil }
            Button(L10n.tr("cameraBodies.cancel"),role: .cancel) { removing = nil }
        } message: { Text(L10n.tr("ipad.fd373fefc8c9")) }
    }
    private func folderButton(_ title: String,icon: String,scope: MobileFolderScope) -> some View {
        Button { model.chooseFolder(scope) } label: {
            HStack {
                Label(title,systemImage: icon).lineLimit(1)
                Spacer(minLength: 2)
                Text("\(model.photos.filter { model.folders.contains($0.id,in: scope) }.count)").font(.caption.monospacedDigit())
            }
        }.foregroundStyle(model.folderScope == scope ? Color.orange : Color.primary)
            .accessibilityLabel(title).accessibilityValue(model.folderScope == scope ? L10n.tr("3f4ebc4aad97") : L10n.tr("0e0c21de6988"))
    }
}
private struct MobileFolderEditor: Identifiable { let id = UUID(); var folder: MobileLibraryFolder? = nil }
private struct MobileFolderEditorView: View {
    @ObservedObject var model: MobileWorkspaceModel
    let folder: MobileLibraryFolder?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                TextField(L10n.tr("ipad.14d34edf50ef"),text: $name).accessibilityIdentifier("library-folder-name")
                if let error { Text(error).foregroundStyle(.red) }
                Text(L10n.tr("ipad.e5005439291a")).font(.caption)
            }.navigationTitle(folder == nil ? L10n.tr("ipad.cf28f49ec597") : L10n.tr("ipad.7249f19c9e4f"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("cameraBodies.cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.tr("cameraBodies.save")) {
                            Task {
                                do {
                                    if let folder { try await model.engine.renameFolder(folder.id,to: name) }
                                    else { _ = try await model.engine.createFolder(name) }
                                    try await model.reload(); dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-library-folder")
                    }
                }
        }.onAppear { name = folder?.name ?? "" }.presentationDetents([.medium,.large]).preferredColorScheme(.dark)
    }
}
#endif
