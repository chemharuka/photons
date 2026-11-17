import PhotonsLocalization
import AppKit
import SwiftUI
import PhotonsPanorama
import PhotonsFileAccess
import UniformTypeIdentifiers

@MainActor
final class LCCProfileLibraryModel: ObservableObject {
    static let shared = LCCProfileLibraryModel()
    let store: LCCProfileStore
    private let installsBundledProfile: Bool
    @Published var profiles:[LCCProfileSummary]=[]
    @Published var selected:UUID? {didSet {if oldValue != selected {readSelected()}}}
    @Published var profile:LCCLensProfile?
    @Published var status=""
    @Published var busy=false
    @Published var error:String?
    @Published private(set) var loadingProfile = false
    private var refreshGeneration = UUID()
    private var readGeneration = UUID()
    private var creator:LCCProfileCreatorWindowController?
    private let queue=DispatchQueue(label:"Photons.lcc.profile.library",qos:.userInitiated)
    init(store:LCCProfileStore = LCCProfileStore(), installBundledProfile:Bool = true) {
        self.store=store;self.installsBundledProfile=installBundledProfile
    }
    func ensureLoaded() {if profiles.isEmpty && !busy {refresh()}}
    func refresh(select id:UUID? = nil) {
        busy=true
        refreshGeneration=UUID()
        let generation=refreshGeneration,store=self.store,install=installsBundledProfile
        queue.async { [weak self] in
            do {
                if install {try store.installBundledProfile()};let catalog=store.catalog()
                DispatchQueue.main.async {
                    guard let self,self.refreshGeneration==generation else {return};self.profiles=catalog.profiles;self.busy=false
                    self.status=L10n.tr("e88329a2fa97" , String(describing: (catalog.profiles.count)))
                    self.error=catalog.issues.isEmpty ? nil:catalog.issues.joined(separator:"\n")
                    let wanted=id ?? self.selected
                    let next=catalog.profiles.first(where:{$0.id==wanted})?.id ?? catalog.profiles.first?.id
                    if self.selected==next {self.readSelected()} else {self.selected=next}
                }
            } catch {DispatchQueue.main.async {guard self?.refreshGeneration==generation else {return};self?.busy=false;self?.error=error.localizedDescription}}
        }
    }
    func readSelected() {
        readGeneration=UUID();profile=nil;loadingProfile=false
        guard let id=selected else {return}
        let generation=readGeneration,store=self.store
        loadingProfile=true
        queue.async { [weak self] in
            do {
                let p=try store.load(id)
                DispatchQueue.main.async {guard self?.readGeneration==generation else {return};self?.profile=p;self?.loadingProfile=false}
            } catch {DispatchQueue.main.async {guard self?.readGeneration==generation else {return};self?.loadingProfile=false;self?.error=error.localizedDescription}}
        }
    }
    func create() {
        if let creator {creator.showWindow(nil);creator.window?.makeKeyAndOrderFront(nil);return}
        let c=LCCProfileCreatorWindowController(store:store) { [weak self] summary in self?.refresh(select:summary.id) }
        c.onClose={ [weak self] in self?.creator=nil };creator=c;c.showWindow(nil);c.window?.makeKeyAndOrderFront(nil)
    }
    func reveal() {
        if let id=selected {NSWorkspace.shared.activateFileViewerSelecting([store.url(for:id)])}
    }
    func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "photonslcc") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = FileAccess(url)
        busy = true; status = L10n.tr("6430d7f1cd18")
        queue.async { [weak self] in
            defer { withExtendedLifetime(access) {} }
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size > 0, size <= 256 * 1024 * 1024 + 65584 else { throw PanoramaFailure(L10n.tr("8c7ee4e7adb6")) }
                let imported = try LCCProfileCodec.decode(Data(contentsOf: url))
                DispatchQueue.main.async { self?.confirmImport(imported) }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    private func confirmImport(_ imported: LCCLensProfile) {
        let store = self.store
        var keepingBoth = false
        if FileManager.default.fileExists(atPath: store.url(for: imported.id).path) {
            let alert = NSAlert(); alert.messageText = L10n.tr("558c9f10c4c6")
            alert.informativeText = L10n.tr("86833a8f747b")
            alert.addButton(withTitle: L10n.tr("lcc.profile.keepBoth"))
            alert.addButton(withTitle: L10n.tr("131b13aa2659")); alert.addButton(withTitle: L10n.tr("2cd0f3be8738"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: keepingBoth = true
            case .alertSecondButtonReturn: break
            default: busy = false; status = L10n.tr("08d7a98d788a"); return
            }
        }
        saveImportedProfile(imported, keepingBoth: keepingBoth)
    }
    func saveImportedProfile(_ imported: LCCLensProfile, keepingBoth: Bool) {
        busy = true
        let store = self.store
        queue.async { [weak self] in
            do {
                let saved = try store.importProfile(imported, keepingBoth: keepingBoth)
                DispatchQueue.main.async { self?.refresh(select: saved.id) }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
    func exportProfile() {
        guard let profile else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "photonslcc") ?? .data]
        panel.nameFieldStringValue = profile.name.replacingOccurrences(of: "/", with: "-") + ".photonslcc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = FileAccess(url)
        busy = true; status = L10n.tr("03523dad439e")
        queue.async { [weak self] in
            defer { withExtendedLifetime(access) {} }
            do {
                try LCCProfileCodec.encode(profile).write(to: url, options: .atomic)
                DispatchQueue.main.async { self?.busy = false; self?.status = L10n.tr("474788f92319" , String(describing: (url.lastPathComponent))) }
            } catch { DispatchQueue.main.async { self?.busy = false; self?.error = error.localizedDescription } }
        }
    }
}

struct LCCProfileLibraryView: View {
    @ObservedObject var model:LCCProfileLibraryModel
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                VStack(alignment:.leading,spacing:4) {
                    Text(L10n.tr("2eeb1676861b")).font(.title.bold())
                    Text(L10n.tr("61f6b1a29661")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("0d624bdac72a")) {model.create()}.buttonStyle(.borderedProminent)
            }
            HSplitView {
                List(selection:$model.selected) {
                    ForEach(model.profiles) { p in
                        VStack(alignment:.leading,spacing:5) {
                            Text(p.name).font(.headline)
                            Text(p.camera).font(.caption).foregroundStyle(.secondary)
                            Text(p.variants.map {L10n.tr("6db6e93d9c3d" , String(describing: ($0.orientation.title)), String(describing: ($0.count)))}.joined(separator:" · ")).font(.caption2)
                        }.padding(.vertical,6).tag(p.id)
                    }
                }.frame(minWidth:270,idealWidth:300,maxWidth:360)
                ScrollView {
                    if let profile=model.profile {
                        VStack(alignment:.leading,spacing:14) {
                            Text(profile.name).font(.title2.bold())
                            Text(profile.camera).foregroundStyle(.secondary)
                            if let body=LCCProfileSummary(profile).calibrationBody {Text(L10n.tr("00f3f3fdc6a8" , String(describing: (body.name)))).font(.caption)}
                            Text(L10n.tr("lcc.profile.compatibility")).font(.caption).foregroundStyle(.secondary)
                            if let aperture=profile.aperture {Text(L10n.tr("9ff1649978c3" , String(format: "%g", aperture)))}
                            Text(profile.notes).font(.callout).textSelection(.enabled)
                            ForEach(profile.orientations) { orientation in
                                let frames=profile.captures(for:orientation)
                                VStack(alignment:.leading,spacing:8) {
                                    Text(L10n.tr("bc22134b1d3f" , String(describing: (orientation.title)), String(describing: (frames.count)))).font(.headline)
                                    LCCProfileCoverageView(captures:frames).frame(height:190)
                                    Text(String(format:L10n.tr("6c3b0465bdf0"),frames.map(\.shiftX).min() ?? 0,frames.map(\.shiftX).max() ?? 0,frames.map(\.shiftY).min() ?? 0,frames.map(\.shiftY).max() ?? 0))
                                        .font(.caption).foregroundStyle(.secondary)
                                }.padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
                            }
                            Text(L10n.tr("462dcac8baeb")).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.tr("89e848ef8755")).font(.caption).foregroundStyle(.secondary)
                        }.padding(16)
                    } else if model.busy || model.loadingProfile {
                        ProgressView(L10n.tr("621708f1b63d")).frame(maxWidth:.infinity,minHeight:280)
                    } else {
                        Text(L10n.tr("lensInfo.empty")).foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:280)
                    }
                }.frame(minWidth:350)
            }
            HStack {
                if model.busy {ProgressView().controlSize(.small)}
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L10n.tr("1b9818e1adfe")) {model.importProfile()}.disabled(model.busy)
                Button(L10n.tr("643e7408e6a7")) {model.exportProfile()}.disabled(model.profile==nil || model.busy)
                Button(L10n.tr("1280364b7f84")) {model.reveal()}.disabled(model.selected==nil)
            }
        }.padding(22).onAppear {model.ensureLoaded()}
        .alert(L10n.tr("2eeb1676861b"),isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) {Button(L10n.tr("f867f3417859")) {model.error=nil}} message: {Text(model.error ?? "")}
    }
}

private struct LCCProfileCoverageView:View {
    let captures:[LCCProfileCapture]
    var body:some View {
        Canvas { context,size in
            guard !captures.isEmpty else {return}
            let bounds=captures.reduce(CGRect.null) {$0.union($1.fieldRect)}
            let scale=min((size.width-24)/bounds.width,(size.height-24)/bounds.height)
            let origin=CGPoint(x:(size.width-bounds.width*scale)/2,y:(size.height-bounds.height*scale)/2)
            for c in captures {
                let frame=c.fieldRect
                let r=CGRect(x:origin.x+(frame.minX-bounds.minX)*scale,
                             y:origin.y+(bounds.maxY-frame.maxY)*scale,width:frame.width*scale,height:frame.height*scale)
                context.fill(Path(r),with:.color(.cyan.opacity(0.045)))
                context.stroke(Path(r),with:.color(.cyan.opacity(0.3)),lineWidth:0.6)
                let p=CGPoint(x:r.midX,y:r.midY)
                context.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(.primary.opacity(0.7)))
            }
        }.background(Color(nsColor:.underPageBackgroundColor),in:RoundedRectangle(cornerRadius:6))
        .accessibilityLabel(L10n.tr("859a15dbf359"))
    }
}
