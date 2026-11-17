import PhotonsLocalization
import AppKit
import PhotonsFileAccess
import SwiftUI
import PhotonsPanorama

@MainActor
final class LCCProfileCreatorWindowController: NSWindowController, NSWindowDelegate {
    private let model:LCCProfileCreatorModel
    var onClose:(()->Void)?
    init(store:LCCProfileStore = LCCProfileStore(),onCreated:@escaping (LCCProfileSummary)->Void) {
        model=LCCProfileCreatorModel(store:store)
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:780),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title=L10n.tr("386d3917a3af");w.minSize=NSSize(width:900,height:680);w.isReleasedWhenClosed=false
        super.init(window:w);w.delegate=self;model.window=w;model.onCreated=onCreated
        let hosting=NSHostingView(rootView:LCCProfileCreatorView(model:model))
        // Adding per-frame metadata must scroll the inspector, not enlarge the window
        // beyond the display and push the creation controls off screen.
        hosting.sizingOptions=[];w.contentView=hosting;w.center()
    }
    required init?(coder:NSCoder) { fatalError("no nib") }
    func windowWillClose(_ notification:Notification) { model.close();onClose?() }
}

@MainActor
private final class LCCProfileCreatorModel: ObservableObject {
    private let store:LCCProfileStore
    init(store:LCCProfileStore) {self.store=store}
    weak var window:NSWindow?
    var onCreated:((LCCProfileSummary)->Void)?
    private var sourceAccess: [FileAccess] = []
    @Published var name=""
    @Published var apertureText=""
    @Published var notes=""
    @Published var sensorLong=43.8
    @Published var sensorShort=32.9
    @Published var cameraBody:PanoramaCameraBody = .alpa12Max
    @Published var frames:[LCCCreationFrame]=[]
    @Published var selected:UUID?
    @Published var busy=false
    @Published var status=L10n.tr("1f9e7c586f1b")
    @Published var error:String?
    @Published var savedURL:URL?
    private var closed=false
    private var token=PanoramaCancellation()
    private let queue=DispatchQueue(label:"Photons.lcc.profile.creator",qos:.userInitiated)
    var selectedIndex:Int? { frames.firstIndex { $0.id==selected } }
    var canCreate:Bool {
        !busy && savedURL==nil && !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !frames.isEmpty &&
        frames.allSatisfy { $0.shiftConfirmed && $0.shiftX.isFinite && $0.shiftY.isFinite && abs($0.shiftX)<=150 && abs($0.shiftY)<=150 } &&
        LCCProfileBuilder.exposureIssue(frames)==nil && (5...100).contains(sensorShort) && sensorLong>=sensorShort && sensorLong<=100
    }
    func close() { closed=true;token.cancel() }
    func cancel() { token.cancel() }
    func setBody(_ body:PanoramaCameraBody) {
        cameraBody=body
        for i in frames.indices {
            frames[i].bodyOrientation=body.canonicalOrientation(frames[i].bodyOrientation)
            frames[i].shiftConfirmed=false
        }
    }
    func applyDirectionToAll(_ direction:PanoramaBodyOrientation) {
        for i in frames.indices where frames[i].bodyOrientation != direction {
            frames[i].bodyOrientation=direction;frames[i].shiftConfirmed=false
        }
    }
    func choose() {
        guard let window else { return }
        let panel=NSOpenPanel();panel.allowsMultipleSelection=true;panel.canChooseDirectories=false
        panel.message=L10n.tr("5d68152f8c27")
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self else { return };self.add(panel.urls)
        }
    }
    func add(_ urls:[URL]) {
        let old=Set(frames.map { $0.source.url.standardizedFileURL })
        let fresh=Array(Set(urls.map(\.standardizedFileURL))).filter { !old.contains($0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard frames.count+fresh.count<=256 else { error=L10n.tr("7814088b5104");return }
        guard !fresh.isEmpty else { return }
        sourceAccess += fresh.map { FileAccess($0) }
        busy=true;status=L10n.tr("8f9015335c4d");token=PanoramaCancellation();let token=self.token
        queue.async { [weak self] in
            do {
                var frames:[LCCCreationFrame]=[]
                for url in fresh { try token.check();frames.append(try LCCCreationFrame(url:url)) }
                try token.check()
                DispatchQueue.main.async {
                    guard let self,!self.closed else { return }
                    if self.frames.isEmpty,let sensor=frames.first?.source.sensor { self.sensorLong=max(sensor.width,sensor.height);self.sensorShort=min(sensor.width,sensor.height) }
                    self.frames+=frames;self.selected=self.selected ?? frames.first?.id;self.busy=false
                    self.status=L10n.tr("e07b75100360" , String(describing: (self.frames.count)))
                }
            } catch { DispatchQueue.main.async { self?.finish(error) } }
        }
    }
    func removeSelected() {
        guard let id=selected else { return };frames.removeAll { $0.id==id };selected=frames.first?.id
    }
    func create() {
        guard canCreate else { return }
        let aperture:Double?
        if apertureText.trimmingCharacters(in:.whitespaces).isEmpty { aperture=nil }
        else if let n=Double(apertureText),n.isFinite,n>0,n<=128 { aperture=n }
        else { error=L10n.tr("95069b4fdd7d");return }
        busy=true;status=L10n.tr("b764a9e30559");token=PanoramaCancellation()
        let token=self.token,frames=self.frames,name=self.name,notes=self.notes,long=self.sensorLong,short=self.sensorShort,body=self.cameraBody,store=self.store
        let onCreated=self.onCreated
        queue.async { [weak self] in
            do {
                let profile=try LCCProfileBuilder.create(name:name,aperture:aperture,notes:notes,frames:frames,
                    sensorLongEdge:long,sensorShortEdge:short,cameraBody:body,cancellation:token) { message in
                        DispatchQueue.main.async { self?.status=message }
                    }
                try token.check()
                let url=try store.save(profile)
                let bytes=(try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
                DispatchQueue.main.async {
                    onCreated?(LCCProfileSummary(profile))
                    guard let self,!self.closed else { return }
                    self.busy=false;self.savedURL=url
                    self.status=L10n.tr("ab05f387f60b" , String(describing: (ByteCountFormatter.string(fromByteCount:Int64(bytes),countStyle:.file))))
                }
            } catch { DispatchQueue.main.async { self?.finish(error) } }
        }
    }
    private func finish(_ error:Error) {
        guard !closed else { return };busy=false
        if error is CancellationError { status=L10n.tr("ccb58a406838") }
        else { self.error=error.localizedDescription;status=L10n.tr("3440d153274a") }
    }
}

private struct LCCProfileCreatorView: View {
    @ObservedObject var model:LCCProfileCreatorModel
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(L10n.tr("386d3917a3af")).font(.title.bold())
            Text(L10n.tr("c5a4291b3c19"))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack {
                TextField(L10n.tr("c90832fa2126"),text:$model.name)
                Text("f/");TextField(L10n.tr("e3df0be2e19a"),text:$model.apertureText).frame(width:55)
                Button(L10n.tr("76d2d245b1cd")) { model.choose() }
            }.textFieldStyle(.roundedBorder).disabled(model.busy || model.savedURL != nil)
            CameraBodyPicker(selection:Binding(get:{model.cameraBody},set:{model.setBody($0)}))
                .frame(width:300).disabled(model.busy || model.savedURL != nil)
            Text(L10n.tr("lcc.profile.bodyProvenance")).font(.caption).foregroundStyle(.secondary)
            HSplitView {
                VStack(alignment:.leading,spacing:10) {
                    HStack { Text(L10n.tr("3e0560dc572d" , String(describing: (model.frames.count)), String(describing: (model.frames.filter(\.shiftConfirmed).count))));Spacer();Button(L10n.tr("f84ea94b0208")) { model.removeSelected() }.disabled(model.selected==nil) }.font(.caption)
                    ScrollView {
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:145),spacing:12)],spacing:12) {
                            ForEach(model.frames) { frame in
                                Button { model.selected=frame.id } label: {
                                    VStack(spacing:6) {
                                        if let cg=frame.thumbnail { Image(decorative:cg,scale:1).resizable().aspectRatio(contentMode:.fit).frame(height:105) }
                                        else { Image(systemName:"photo").frame(height:105) }
                                        Text(frame.source.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                        Text(L10n.tr("52e99ef48748" , String(describing: (frame.bodyOrientation.rawValue)), String(describing: (frame.relativeOrientation.title)))).font(.caption2).foregroundStyle(.secondary)
                                        Label(frame.shiftConfirmed ? String(format:"H %+.1f / V %+.1f mm",frame.shiftX,frame.shiftY):L10n.tr("9c084cf315a5"),systemImage:frame.shiftConfirmed ? "checkmark.circle.fill":"circle")
                                            .font(.caption2).foregroundStyle(frame.shiftConfirmed ? Color.green:Color.orange)
                                    }.padding(8).frame(maxWidth:.infinity)
                                        .background(model.selected==frame.id ? Color.accentColor.opacity(0.15):Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(4)
                        if model.frames.isEmpty { ContentUnavailableView(L10n.tr("f8d53c4e0187"),systemImage:"camera.metering.center.weighted",description:Text(L10n.tr("991602e4e93f"))) }
                    }
                }.frame(minWidth:460)
                inspector.frame(width:290).padding(.leading,12)
            }.frame(minHeight:0,maxHeight:.infinity).disabled(model.busy || model.savedURL != nil)
            if let issue=LCCProfileBuilder.exposureIssue(model.frames) { Text(issue).font(.caption).foregroundStyle(.orange) }
            if model.frames.contains(where: { $0.iso==nil || $0.exposureSeconds==nil }) {
                Text(L10n.tr("191656941071")).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if model.busy { Button(L10n.tr("2cd0f3be8738")) { model.cancel() } }
                if let url=model.savedURL {
                    Button(L10n.tr("1280364b7f84")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    Button(L10n.tr("c0b3fbff51cc")) { model.window?.close() }.buttonStyle(.borderedProminent)
                } else { Button(L10n.tr("4a548bc641dd")) { model.create() }.buttonStyle(.borderedProminent).disabled(!model.canCreate) }
            }
        }.padding(22)
        .alert(L10n.tr("386d3917a3af"),isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button(L10n.tr("f867f3417859")) {model.error=nil} } message: { Text(model.error ?? "") }
    }
    private var inspector:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:14) {
                if let i=model.selectedIndex {
                    Text(model.frames[i].source.url.lastPathComponent).font(.headline).textSelection(.enabled)
                    Text(L10n.tr("7c3c44699597")).font(.headline)
                    PanoramaBodyOrientationPicker(cameraBody:model.cameraBody,selection:$model.frames[i].bodyOrientation)
                        .onChange(of:model.frames[i].bodyOrientation) {_,_ in model.frames[i].shiftConfirmed=false}
                    Button(L10n.tr("32438bd5e3da")) {model.applyDirectionToAll(model.frames[i].bodyOrientation)}.controlSize(.small)
                    Picker(L10n.tr("ed6ca829152b"),selection:$model.frames[i].orientation) {
                        ForEach(LCCCaptureOrientation.allCases) { Text($0.title).tag($0) }
                    }.onChange(of:model.frames[i].orientation) {_,_ in model.frames[i].shiftConfirmed=false}
                    Text(L10n.tr("7abedf61e774" , String(describing: (model.frames[i].relativeOrientation.title)))).font(.caption).foregroundStyle(.secondary)
                    Text(L10n.tr("a1cde73e9c42")).font(.headline)
                    HStack { Text(L10n.tr("e7f3667f84e8")).frame(width:65,alignment:.leading);TextField("mm",value:$model.frames[i].shiftX,format:.number) }
                    HStack { Text(L10n.tr("ef216dc818fc")).frame(width:65,alignment:.leading);TextField("mm",value:$model.frames[i].shiftY,format:.number) }
                    Text(L10n.tr("97203d12e496")).font(.caption).foregroundStyle(.secondary)
                    Toggle(L10n.tr("d59031c83f0e"),isOn:$model.frames[i].shiftConfirmed)
                    Text(model.frames[i].source.camera).font(.caption)
                    Text("ISO \(model.frames[i].iso.map { String(format:"%.0f",$0) } ?? L10n.tr("4d8c1c5b4283")) · \(model.frames[i].exposureSeconds.map { String(format:L10n.tr("8e55403e96e1"),$0) } ?? L10n.tr("b43a1481512d"))").font(.caption).foregroundStyle(.secondary)
                } else { Text(L10n.tr("e83f547dcd27")).foregroundStyle(.secondary) }
                Divider()
                Text(L10n.tr("10a0d92065bd")).font(.headline)
                HStack { Text(L10n.tr("dc4ffb23c9a3"));TextField("mm",value:$model.sensorLong,format:.number);Text(L10n.tr("d36b0efe1ed8"));TextField("mm",value:$model.sensorShort,format:.number) }
                HStack {
                    Button("44 × 33") {model.sensorLong=43.8;model.sensorShort=32.9}
                    Button("54 × 40") {model.sensorLong=54;model.sensorShort=40}
                    Button("36 × 24") {model.sensorLong=36;model.sensorShort=24}
                }.controlSize(.small)
                Text(L10n.tr("d4fe7326c0a1")).font(.caption).foregroundStyle(.secondary)
                TextField(L10n.tr("77152b07ba75"),text:$model.notes,axis:.vertical).lineLimit(2...4)
                Text(L10n.tr("80748924f490")).font(.caption).foregroundStyle(.secondary)
            }.textFieldStyle(.roundedBorder)
        }
    }
}
