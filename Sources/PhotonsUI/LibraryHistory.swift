import PhotonsLocalization
import Foundation
import SwiftUI
import AppKit
import PhotonsFileAccess

public struct LibraryHistoryEntry:Codable,Identifiable,Equatable {
    public var path:String
    public var lastOpened:Date
    public var id:String {path}
    public var url:URL {URL(fileURLWithPath:path)}
}
public enum LibraryHistory {
    public static let key="photons.libraryHistory.v1"
    public static let changed=Notification.Name("photons.libraryHistoryChanged")
    public static func entries(in store:RecentLibrary.Store=UserDefaults.standard)->[LibraryHistoryEntry] {
        var entries=store.string(forKey:key).flatMap {$0.data(using:.utf8)}.flatMap {try? JSONDecoder().decode([LibraryHistoryEntry].self,from:$0)} ?? []
        if store.string(forKey:key) == nil, let defaults=store as? UserDefaults, defaults === UserDefaults.standard {
            for url in FileAccessStore.shared.rememberedURLs() where url.pathExtension == "photonslibrary" {
                if !entries.contains(where:{$0.path==url.standardizedFileURL.path}) {
                    entries.append(.init(path:url.standardizedFileURL.path,lastOpened:.distantPast))
                }
            }
            if !entries.isEmpty {save(entries,in:store)}
        }
        if let recent=RecentLibrary.recall(from:store),!entries.contains(where:{$0.path==recent.standardizedFileURL.path}) {
            entries.append(.init(path:recent.standardizedFileURL.path,lastOpened:.distantPast))
        }
        return entries.sorted {$0.lastOpened>$1.lastOpened}
    }
    public static func remember(_ url:URL,in store:RecentLibrary.Store=UserDefaults.standard) {
        var entries=entries(in:store);entries.removeAll {$0.path==url.standardizedFileURL.path}
        entries.insert(.init(path:url.standardizedFileURL.path,lastOpened:Date()),at:0)
        save(entries,in:store)
    }
    public static func remove(_ url:URL,in store:RecentLibrary.Store=UserDefaults.standard) {
        if RecentLibrary.recall(from:store)?.standardizedFileURL.path==url.standardizedFileURL.path {RecentLibrary.forget(in:store)}
        save(entries(in:store).filter {$0.path != url.standardizedFileURL.path},in:store)
    }
    private static func save(_ entries:[LibraryHistoryEntry],in store:RecentLibrary.Store) {
        if let data=try? JSONEncoder().encode(entries),let string=String(data:data,encoding:.utf8) {store.set(string,forKey:key)}
        NotificationCenter.default.post(name:changed,object:nil)
    }
}

struct LibraryHistoryView:View {
    @State private var entries=LibraryHistory.entries()
    @State private var error:String?
    private var editor:EditorWindowController? {NSApp.windows.compactMap {$0.windowController as? EditorWindowController}.first}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(L10n.tr("66ccd087d70e")).settingsLibraryHint()
            HStack {
                Button(L10n.tr("5b6408caf9a6")) {editor?.openLibraryPanel()}
                Button(L10n.tr("f9af46c99fd4")) {editor?.createLibraryAction(nil)}
            }
            if entries.isEmpty {Text(L10n.tr("096585910b99")).foregroundStyle(.secondary)}
            ForEach(entries) {entry in
                let access=FileAccessStore.shared.access(to:entry.url)
                let available=RecentLibrary.defaultIsDirectory(access.url)
                VStack(alignment:.leading,spacing:7) {
                    HStack {
                        Image(systemName:"photo.stack")
                        Text(entry.url.deletingPathExtension().lastPathComponent).font(.headline)
                        Spacer()
                        Text(editor?.session.libraryURL?.standardizedFileURL==entry.url.standardizedFileURL ? L10n.tr("32364c3f65af"):(available ? L10n.tr("4d99c976beb8"):L10n.tr("55c1247ebaa9")))
                            .font(.caption).foregroundStyle(available ? Color.secondary:.orange)
                    }
                    Text(entry.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    HStack {
                        Button(L10n.tr("c771248e511f")) {
                            do {try editor?.openLibrary(at:entry.url);editor?.showWindow(nil)}
                            catch {self.error=error.localizedDescription}
                        }.disabled(!available)
                        Button(L10n.tr("1280364b7f84")) {NSWorkspace.shared.activateFileViewerSelecting([access.url])}.disabled(!available)
                        Spacer()
                        Button(L10n.tr("081ed577f0c2")) {LibraryHistory.remove(entry.url);entries=LibraryHistory.entries()}
                    }.controlSize(.small)
                }.padding(12).background(Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for:LibraryHistory.changed)) {_ in entries=LibraryHistory.entries()}
        .alert(L10n.tr("df3be042e1cf"),isPresented:Binding(get:{error != nil},set:{if !$0 {error=nil}})) {Button(L10n.tr("f867f3417859")) {error=nil}} message:{Text(error ?? "")}
    }
}
private extension View {
    func settingsLibraryHint()->some View {font(.system(size:12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)}
}
