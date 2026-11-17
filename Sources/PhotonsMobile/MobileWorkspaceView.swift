#if os(iOS)
import SwiftUI
import PhotonsLocalization
import UIKit
import UniformTypeIdentifiers
import PhotonsCore
import PhotonsPanorama

public struct MobileWorkspaceView: View {
    @StateObject private var model = MobileWorkspaceModel()
    @State private var importer = false
    @State private var panoramaWorkspace = false
    @State private var settingsWorkspace = false
    @State private var selectMode = false
    @State private var inspectorSheet = false
    @State private var sidebarVisible = false
    @State private var sidebarSheet = false
    @State private var inspectorVisible = false
    @State private var wideLayout = true
    @State private var pinchStart: Double?
    @State private var tool: MobileSheet?
    @AppStorage("photons.mobile.thumbnailSize") private var thumbnailSize = 180.0
    @State private var search = ""
    private var visiblePhotos: [MobilePhoto] { model.folderPhotos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) } }
    public init() {}
    public var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    workspaceToolbar
                    Divider()
                    HStack(spacing: 0) {
                        if sidebarVisible && geometry.size.width >= 950 { libraryRail.frame(width: 190); Divider() }
                        VStack(spacing: 0) {
                            taskBar
                            if model.showGrid { libraryGrid } else { canvas }
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if geometry.size.width >= 950 && inspectorVisible {
                            Divider()
                            MobileInspector(model: model).frame(width: 310)
                        }
                    }
                }
                .background(Color(white: 0.075))
                .onAppear { wideLayout = geometry.size.width >= 950 }
                .onChange(of: geometry.size.width) { _,width in wideLayout = width >= 950 }
            }

            .navigationTitle("Photons Studio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark).tint(.orange)
        .task { await model.start() }
        .onChange(of: model.showGrid) { _,grid in if !grid && model.plan != nil { inspectorVisible = true } }
        .onChange(of: model.folderScope) { _,_ in selectMode = false }
        .onChange(of: inspectorSheet) { _,visible in
            if !visible && model.showGrid && !selectMode { model.clearSelection() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.image, .rawImage, .folder], allowsMultipleSelection: true) { result in
            do { model.importPhotos(try result.get()) } catch { model.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $panoramaWorkspace, onDismiss: { model.endPanorama() }) { MobilePanoramaFlow(model: model) }
        .fullScreenCover(isPresented: $settingsWorkspace) { MobileSettingsWorkspace(model: model) }
        .sheet(item: $tool) { sheet in
            NavigationStack {
                Group {
                    switch sheet {
                    case .lcc: MobileLCCSheet(model: model)
                    case .profiles: MobileProfilesSheet(model: model)
                    case .export: MobileExportSheet(model: model)
                    case .capabilities: MobileCapabilitiesView()
                    }
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("3fd47edce45b")) { tool = nil } } }
            }.preferredColorScheme(.dark).tint(.orange)
        }
        .sheet(isPresented: $sidebarSheet) {
            NavigationStack { libraryRail.toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("c0b3fbff51cc")) { sidebarSheet = false } } } }
                .preferredColorScheme(.dark).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $inspectorSheet) {
            NavigationStack { MobileInspector(model: model).toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("c0b3fbff51cc")) { inspectorSheet = false } } } }
                .preferredColorScheme(.dark).presentationDetents([.large])
        }
        .alert("Photons Studio", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.tr("slices.ok"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .environment(\.locale,Locale(identifier: L10n.language))
    }
    private var workspaceToolbar: some View {
        HStack(spacing: 16) {
            Button {
                if wideLayout { sidebarVisible.toggle() } else { sidebarSheet = true }
            } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel(L10n.tr("ipad.3339973aae80")).accessibilityIdentifier("toggle-sidebar")
            Text("Photons").font(.headline)
            Divider().frame(height: 20)
            Button { model.showGrid = true } label: { Image(systemName: "number") }
                .foregroundStyle(model.showGrid ? Color.orange : .secondary)
                .accessibilityLabel(L10n.tr("ipad.47da4e5507b6")).accessibilityIdentifier("grid-view")
            Button { model.showGrid = false; model.render() } label: { Image(systemName: "rectangle") }
                .foregroundStyle(model.showGrid ? Color.secondary : .orange).disabled(model.active == nil)
                .accessibilityLabel(L10n.tr("ipad.c3470af228c5")).accessibilityIdentifier("single-view")
            Spacer(minLength: 8)
            Button { importer = true } label: { Image(systemName: "plus") }
                .disabled(model.busy).accessibilityLabel(L10n.tr("ipad.6b071abc6cf0")).accessibilityIdentifier("import-photos")
            Button(model.hdr ? "HDR" : "SDR") { model.toggleHDR() }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(model.hdr ? .orange : .gray).accessibilityIdentifier("display-mode").disabled(model.busy)
            if model.selected.count >= 2 {
                Button { model.beginPanorama(); panoramaWorkspace = true } label: { Image(systemName: "pano") }
                    .disabled(model.busy).keyboardShortcut("m", modifiers: .control)
                    .accessibilityLabel(L10n.tr("ipad.2be61912014b")).accessibilityIdentifier("panorama-tool")
            }
            Menu {
                Button(L10n.tr("ipad.40c527f3f714"), systemImage: "camera.filters") { tool = .lcc }.disabled(model.active == nil)
                Button(L10n.tr("ipad.bf744e98a728"), systemImage: "camera.aperture") { tool = .profiles }
                Divider()
                Button(L10n.tr("ipad.ba7bc9604cf8"), systemImage: "checklist") { tool = .capabilities }
            } label: { Image(systemName: "slider.horizontal.3") }
                .disabled(model.busy).accessibilityLabel(L10n.tr("5ca6730d4415")).accessibilityIdentifier("tools-menu")
            Button {
                if wideLayout {
                    inspectorVisible.toggle()
                    if !inspectorVisible && model.showGrid && !selectMode { model.clearSelection() }
                } else { inspectorSheet = true }
            } label: { Image(systemName: "sidebar.right") }
                .accessibilityLabel(L10n.tr("ipad.5602d0e1c70b")).accessibilityIdentifier("toggle-inspector")
            Button { tool = .export } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(!model.canExport || model.busy).accessibilityLabel(L10n.tr("76420433f22d")).accessibilityIdentifier("export-photo")
            Button { settingsWorkspace = true } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: .control).accessibilityLabel(L10n.tr("df3d58c7d84b")).accessibilityIdentifier("settings-button")
        }.font(.body).buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 58).background(Color(white: 0.12))
    }
    private func tapPhoto(_ photo: MobilePhoto) {
        if selectMode {
            model.toggleSelection(photo)
        } else {
            let same = model.active?.id == photo.id
            if same && wideLayout && inspectorVisible {
                inspectorVisible = false; model.clearSelection(); return
            }
            model.selected = [photo.id]
            model.select(photo)
            if wideLayout { inspectorVisible = true }
            else { inspectorSheet = true }
        }
    }
    private func beginSelection(_ photo: MobilePhoto) {
        selectMode = true
        model.selected = [photo.id]
        model.select(photo)
    }
    private var libraryRail: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("LIBRARY", systemImage: "photo.stack").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView { MobileFolderList(model: model) }.frame(maxHeight: 300)
            Text(L10n.tr("ipad.74b5d9973dbd", String(describing: (model.photos.count)))).font(.caption).foregroundStyle(.secondary)
            Divider()
            Label("WORKFLOW", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.selected.count >= 2 { Button(L10n.tr("ipad.2be61912014b"), systemImage: "pano") { model.beginPanorama(); panoramaWorkspace = true }.disabled(model.busy) }
            Button(L10n.tr("ipad.40c527f3f714"), systemImage: "camera.filters") { tool = .lcc }.disabled(model.active == nil || model.busy)
            Button(L10n.tr("ipad.bf744e98a728"), systemImage: "camera.aperture") { tool = .profiles }.disabled(model.busy)
            if !MobileSamples.boston.isEmpty {
                Divider()
                Button(L10n.tr("ipad.6424228301b9"), systemImage: "photo.badge.plus") { model.importPhotos(MobileSamples.boston) }
                    .disabled(model.busy).accessibilityIdentifier("load-boston")
                Text(L10n.tr("ipad.837667e77119")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(L10n.tr("ipad.3e79f5141d8d")).font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxHeight: .infinity).background(Color(white: 0.1))
    }
    @ViewBuilder private var taskBar: some View {
        if !model.status.isEmpty {
            HStack(spacing: 12) {
                if let fraction = model.progress { ProgressView(value: fraction).frame(width: 110) }
                else { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                if model.busy { Button(L10n.tr("cameraBodies.cancel")) { model.cancel() }.font(.caption) }
            }.padding(12).background(.thinMaterial).accessibilityIdentifier("task-progress")
        }
        if let url = model.output {
            HStack {
                Label(L10n.tr("ipad.4f0424e48178", String(describing: (url.lastPathComponent))), systemImage: "checkmark.circle").font(.caption).lineLimit(1)
                Spacer()
                ShareLink(item: url) { Label(L10n.tr("ipad.3d1808eb43ea"), systemImage: "square.and.arrow.up") }.font(.caption)
                Button { model.output = nil } label: { Image(systemName: "xmark") }
            }.padding(12).background(Color.green.opacity(0.12)).accessibilityIdentifier("export-result")
        }
    }
    private var libraryGrid: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(L10n.tr("ipad.38affea33a68"), text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text(L10n.tr("ipad.acc5536c4d87", String(describing: (model.selected.count)))).font(.caption).foregroundStyle(.secondary)
                if !model.selected.isEmpty {
                    Menu(L10n.tr("ipad.91d631e150a3")) {
                        Button(L10n.tr("ipad.d64dc9ae400c")) { model.moveSelection(to: nil) }
                        ForEach(model.folders.folders) { folder in Button(folder.name) { model.moveSelection(to: folder.id) }.accessibilityLabel(L10n.tr("ipad.699bb2f5f6e9", String(describing: (folder.name)))) }
                    }.disabled(model.busy).accessibilityIdentifier("move-to-folder")
                }
                if selectMode {
                    Button(L10n.tr("c0b3fbff51cc")) { selectMode = false; model.selected = model.active.map { [$0.id] } ?? [] }.accessibilityIdentifier("finish-selection")
                }
            }.padding(12)
            if model.photos.isEmpty {
                ContentUnavailableView {
                    Label(L10n.tr("ipad.c43b058bf47d"), systemImage: "photo.on.rectangle.angled")
                } description: { Text(L10n.tr("ipad.e25172cd7883")) }
                actions: {
                    Button(L10n.tr("ipad.497f31b6fd7f")) { importer = true }.buttonStyle(.borderedProminent)
                    if !MobileSamples.boston.isEmpty {
                        Button(L10n.tr("ipad.6424228301b9")) { model.importPhotos(MobileSamples.boston) }
                            .accessibilityIdentifier("load-boston")
                    }
                    Button(L10n.tr("ipad.09d66e67c4d3")) {
                        Task { do { let urls = try await Task.detached { try MobileSamples.create() }.value; model.importPhotos(urls) } catch { model.error = error.localizedDescription } }
                    }.accessibilityIdentifier("load-samples")
                }
            } else if visiblePhotos.isEmpty {
                ContentUnavailableView(L10n.tr("ipad.d763f5e2f3ba"),systemImage: "folder",description: Text(L10n.tr("ipad.bcff7cb83f35")))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 14) {
                        ForEach(visiblePhotos) { photo in
                            VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .topTrailing) {
                                        Color(white: 0.12)
                                        if let frame = model.thumbnails[photo.id] {
                                            MobileThumbnail(image: frame.image,hdr: model.hdr).padding(5)
                                        } else if model.previewErrors[photo.id] != nil { Image(systemName: "exclamationmark.triangle").frame(maxWidth: .infinity, maxHeight: .infinity) }
                                        else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                                        if selectMode || model.selected.contains(photo.id) {
                                            Image(systemName: model.selected.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                                .font(.title3).foregroundStyle(model.selected.contains(photo.id) ? .orange : .white).padding(8)
                                        }
                                    }.frame(height: thumbnailSize * 0.82).clipShape(RoundedRectangle(cornerRadius: 6))
                                    Text(photo.name).font(.caption).lineLimit(1).foregroundStyle(.primary)
                                    Text(photo.rating > 0 ? String(repeating: "★", count: photo.rating) : "\(photo.width) × \(photo.height)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }.padding(7).background(model.selected.contains(photo.id) ? Color.orange.opacity(0.12) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                            .gesture(LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture(count: 2).exclusively(before: TapGesture())).onEnded { value in
                                switch value {
                                case .first: beginSelection(photo)
                                case .second(.first): selectMode = false; model.select(photo, open: true)
                                case .second(.second): tapPhoto(photo)
                                }
                            })
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { tapPhoto(photo) }
                            .accessibilityAction(named: Text(L10n.tr("ipad.6d14bf1f6104"))) { selectMode = false; model.select(photo, open: true) }
                            .accessibilityIdentifier("photo-\(photo.name)")
                            .accessibilityValue(model.selected.contains(photo.id) ? L10n.tr("3f4ebc4aad97") : L10n.tr("0e0c21de6988"))

                        }
                    }.padding(14)
                }
                .background(Color(white: 0.075)).contentShape(Rectangle())
                .accessibilityIdentifier("photo-grid")
                .simultaneousGesture(MagnificationGesture().onChanged { scale in
                    if pinchStart == nil { pinchStart = thumbnailSize }
                    thumbnailSize = min(340, max(100, (pinchStart ?? thumbnailSize) * scale))
                }.onEnded { _ in pinchStart = nil })
            }
        }
    }
    private var canvas: some View {
        ZStack {
            Color(white: 0.055)
            if let image = model.frame?.image {
                MobilePhotoCanvas(image: image, hdr: model.hdr, identity: model.plan == nil ? (model.active?.id ?? "") : "panorama",
                                  fullSize: model.canvasSize,detail: model.detailFrame,detailStatus: model.detailStatus,
                                  onViewportChange: { model.requestDetail($0) },
                                  onNavigate: { model.movePhoto(by: $0, among: visiblePhotos) })
                    .padding(20)
            } else { ContentUnavailableView(L10n.tr("ipad.defc2cfd9694"), systemImage: "photo") }
            if model.rendering { ProgressView().padding(16).background(.ultraThinMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding() }
            if model.plan == nil, let photo = model.active {
                HStack {
                    Button { model.movePhoto(by: -1, among: visiblePhotos) } label: { Image(systemName: "chevron.left") }
                        .disabled(visiblePhotos.first?.id == photo.id || model.busy).accessibilityIdentifier("previous-photo").accessibilityLabel(L10n.tr("ipad.c7cd30884cd6"))
                    Text(photo.name).font(.caption).lineLimit(1).accessibilityIdentifier("current-photo-name")
                    Button { model.movePhoto(by: 1, among: visiblePhotos) } label: { Image(systemName: "chevron.right") }
                        .disabled(visiblePhotos.last?.id == photo.id || model.busy).accessibilityIdentifier("next-photo").accessibilityLabel(L10n.tr("ipad.a471f92bee76"))
                }.padding(10).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding(12)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum MobileSheet: String, Identifiable { case lcc, profiles, export, capabilities; var id: String { rawValue } }

struct MobileThumbnail: UIViewRepresentable {
    let image: CGImage
    let hdr: Bool
    func makeUIView(context: Context) -> MobilePreviewSurface { MobilePreviewSurface() }
    func updateUIView(_ view: MobilePreviewSurface,context: Context) { view.present(image,hdr: hdr) }
}

/// Present generated floating-point pixels directly. UIImage(cgImage:) does not reliably mark
/// these as HDR, even when CGImage carries headroom; its image-view path can flatten the result.
final class MobilePreviewSurface: UIView {
    func present(_ image: CGImage,hdr: Bool) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contentsGravity = .resizeAspect
        layer.contents = image
        layer.toneMapMode = .automatic
        let extended = hdr && image.contentHeadroom > 1
        if #available(iOS 26.0, *) { layer.preferredDynamicRange = extended ? .high : .standard }
        else { layer.wantsExtendedDynamicRangeContent = extended }
        CATransaction.commit()
    }
}

/// Keep the display limitation visible without baking a simulated HDR look into the image data.
final class MobilePhotoScrollView: UIScrollView {
    var hdr = false
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
    private let notice = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        notice.font = .preferredFont(forTextStyle: .caption2)
        notice.textColor = .secondaryLabel; notice.backgroundColor = .secondarySystemBackground
        notice.layer.cornerRadius = 5; notice.clipsToBounds = true
        notice.text = L10n.tr("ipad.b31119459c58")
        notice.accessibilityIdentifier = "hdr-display-limitation"
        notice.isHidden = true; notice.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notice)
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: frameLayoutGuide.leadingAnchor,constant: 12),
            notice.bottomAnchor.constraint(equalTo: frameLayoutGuide.bottomAnchor,constant: -12)
        ])
        for name in [UIScreen.brightnessDidChangeNotification,UIScreen.referenceDisplayModeStatusDidChangeNotification,UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self,selector: #selector(updateDisplayNotice),name: name,object: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    override func didMoveToWindow() { super.didMoveToWindow(); updateDisplayNotice() }
    @objc func updateDisplayNotice() {
        notice.isHidden = !hdr || (window?.screen.potentialEDRHeadroom ?? 1) > 1
        bringSubviewToFront(notice)
    }
}
#endif
