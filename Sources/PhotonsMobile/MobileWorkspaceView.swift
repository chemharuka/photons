#if os(iOS)
import SwiftUI
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in model.memoryWarning() }
        .fileImporter(isPresented: $importer, allowedContentTypes: [.image, .rawImage, .folder], allowsMultipleSelection: true) { result in
            do { model.importPhotos(try result.get()) } catch { model.error = error.localizedDescription }
        }
        .fullScreenCover(isPresented: $panoramaWorkspace, onDismiss: { if model.plan == nil { model.render() } }) { MobilePanoramaFlow(model: model) }
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
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { tool = nil } } }
            }.preferredColorScheme(.dark).tint(.orange)
        }
        .sheet(isPresented: $sidebarSheet) {
            NavigationStack { libraryRail.toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sidebarSheet = false } } } }
                .preferredColorScheme(.dark).presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $inspectorSheet) {
            NavigationStack { MobileInspector(model: model).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { inspectorSheet = false } } } }
                .preferredColorScheme(.dark).presentationDetents([.large])
        }
        .alert("Photons Studio", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var workspaceToolbar: some View {
        HStack(spacing: 16) {
            Button {
                if wideLayout { sidebarVisible.toggle() } else { sidebarSheet = true }
            } label: { Image(systemName: "sidebar.left") }
                .accessibilityLabel("Toggle library sidebar").accessibilityIdentifier("toggle-sidebar")
            Text("Photons").font(.headline)
            Divider().frame(height: 20)
            Button { model.showGrid = true } label: { Image(systemName: "number") }
                .foregroundStyle(model.showGrid ? Color.orange : .secondary)
                .accessibilityLabel("Grid view").accessibilityIdentifier("grid-view")
            Button { model.showGrid = false; model.render() } label: { Image(systemName: "rectangle") }
                .foregroundStyle(model.showGrid ? Color.secondary : .orange).disabled(model.active == nil)
                .accessibilityLabel("Single photo view").accessibilityIdentifier("single-view")
            Spacer(minLength: 8)
            Button { importer = true } label: { Image(systemName: "plus") }
                .disabled(model.busy).accessibilityLabel("Import photos").accessibilityIdentifier("import-photos")
            Button(model.hdr ? "HDR" : "SDR") { model.toggleHDR() }
                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(model.hdr ? .orange : .gray).accessibilityIdentifier("display-mode").disabled(model.busy)
            if model.selected.count >= 2 {
                Button { panoramaWorkspace = true } label: { Image(systemName: "pano") }
                    .disabled(model.busy).keyboardShortcut("m", modifiers: .control)
                    .accessibilityLabel("Panorama").accessibilityIdentifier("panorama-tool")
            }
            Menu {
                Button("LCC correction", systemImage: "camera.filters") { tool = .lcc }.disabled(model.active == nil)
                Button("Lens profiles", systemImage: "camera.aperture") { tool = .profiles }
                Divider()
                Button("Preview capabilities", systemImage: "checklist") { tool = .capabilities }
            } label: { Image(systemName: "slider.horizontal.3") }
                .disabled(model.busy).accessibilityLabel("Tools").accessibilityIdentifier("tools-menu")
            Button { if wideLayout { inspectorVisible.toggle() } else { inspectorSheet = true } } label: { Image(systemName: "sidebar.right") }
                .accessibilityLabel("Toggle photo information").accessibilityIdentifier("toggle-inspector")
            Button { tool = .export } label: { Image(systemName: "square.and.arrow.up") }
                .disabled(!model.canExport || model.busy).accessibilityLabel("Export").accessibilityIdentifier("export-photo")
            Button { settingsWorkspace = true } label: { Image(systemName: "gearshape") }
                .keyboardShortcut(",", modifiers: .control).accessibilityLabel("Settings").accessibilityIdentifier("settings-button")
        }.font(.body).buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 58).background(Color(white: 0.12))
    }
    private func tapPhoto(_ photo: MobilePhoto) {
        if selectMode {
            model.toggleSelection(photo)
        } else {
            let same = model.active?.id == photo.id
            model.selected = [photo.id]
            model.select(photo)
            if wideLayout { inspectorVisible = same ? !inspectorVisible : true }
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
            Button { model.showGrid = true } label: { Label("All photographs", systemImage: "square.grid.2x2") }
            Text("\(model.photos.count) photographs").font(.caption).foregroundStyle(.secondary)
            Divider()
            Label("WORKFLOW", systemImage: "slider.horizontal.3").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.selected.count >= 2 { Button("Panorama", systemImage: "pano") { panoramaWorkspace = true }.disabled(model.busy) }
            Button("LCC correction", systemImage: "camera.filters") { tool = .lcc }.disabled(model.active == nil || model.busy)
            Button("Lens profiles", systemImage: "camera.aperture") { tool = .profiles }.disabled(model.busy)
            if !MobileSamples.boston.isEmpty {
                Divider()
                Button("Load Boston test photos", systemImage: "photo.badge.plus") { model.importPhotos(MobileSamples.boston) }
                    .disabled(model.busy).accessibilityIdentifier("load-boston")
                Text("4 RAWs · 43XL profile included").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("iPad development preview").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).frame(maxHeight: .infinity).background(Color(white: 0.1))
    }
    @ViewBuilder private var taskBar: some View {
        if !model.status.isEmpty {
            HStack(spacing: 12) {
                if let fraction = model.progress { ProgressView(value: fraction).frame(width: 110) }
                else { ProgressView().controlSize(.small) }
                Text(model.status).font(.caption).lineLimit(1)
                Spacer()
                if model.busy { Button("Cancel") { model.cancel() }.font(.caption) }
            }.padding(12).background(.thinMaterial).accessibilityIdentifier("task-progress")
        }
        if let url = model.output {
            HStack {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle").font(.caption).lineLimit(1)
                Spacer()
                ShareLink(item: url) { Label("Save / Share", systemImage: "square.and.arrow.up") }.font(.caption)
                Button { model.output = nil } label: { Image(systemName: "xmark") }
            }.padding(12).background(Color.green.opacity(0.12)).accessibilityIdentifier("export-result")
        }
    }
    private var libraryGrid: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search photographs", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Text("\(model.selected.count) selected").font(.caption).foregroundStyle(.secondary)
                if selectMode {
                    Button("Done") { selectMode = false; model.selected = model.active.map { [$0.id] } ?? [] }.accessibilityIdentifier("finish-selection")
                }
            }.padding(12)
            if model.photos.isEmpty {
                ContentUnavailableView {
                    Label("Your photographs, everywhere", systemImage: "photo.on.rectangle.angled")
                } description: { Text("Import photos from Files or an external drive. Originals are copied into this iPad's library.") }
                actions: {
                    Button("Import photographs") { importer = true }.buttonStyle(.borderedProminent)
                    if !MobileSamples.boston.isEmpty {
                        Button("Load Boston test photos") { model.importPhotos(MobileSamples.boston) }
                            .accessibilityIdentifier("load-boston")
                    }
                    Button("Try sample photographs") {
                        Task { do { let urls = try await Task.detached { try MobileSamples.create() }.value; model.importPhotos(urls) } catch { model.error = error.localizedDescription } }
                    }.accessibilityIdentifier("load-samples")
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 12)], spacing: 14) {
                        ForEach(model.photos.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { photo in
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
                            .gesture(LongPressGesture(minimumDuration: 0.45).exclusively(before: TapGesture()).onEnded { value in
                                switch value {
                                case .first: beginSelection(photo)
                                case .second: tapPhoto(photo)
                                }
                            })
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { tapPhoto(photo) }
                            .accessibilityIdentifier("photo-\(photo.name)")

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
                MobilePhotoCanvas(image: image, hdr: model.hdr, identity: model.plan == nil ? (model.active?.id ?? "") : "panorama")
                    .padding(20).accessibilityIdentifier("photo-canvas")
            } else { ContentUnavailableView("Select a photograph", systemImage: "photo") }
            if model.rendering { ProgressView().padding(16).background(.ultraThinMaterial, in: Capsule()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum MobileSheet: String, Identifiable { case lcc, profiles, export, capabilities; var id: String { rawValue } }

/// UIScrollView provides pinch-to-zoom and panning without changing the shared render geometry.
struct MobilePhotoCanvas: UIViewRepresentable {
    let image: CGImage
    let hdr: Bool
    let identity: String
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MobilePhotoScrollView {
        let scroll = MobilePhotoScrollView(); scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 6
        scroll.delegate = context.coordinator; scroll.backgroundColor = .clear
        let view = context.coordinator.imageView; view.backgroundColor = .clear
        scroll.addSubview(view); return scroll
    }
    func updateUIView(_ scroll: MobilePhotoScrollView, context: Context) {
        let view = context.coordinator.imageView
        if context.coordinator.identity != identity {
            scroll.setZoomScale(1, animated: false); context.coordinator.identity = identity
        }
        view.present(image,hdr: hdr)
        scroll.hdr = hdr; scroll.updateDisplayNotice()
        if scroll.zoomScale == 1 { view.frame = scroll.bounds; scroll.contentSize = scroll.bounds.size }
        // Bounds can be zero on the first SwiftUI update; the view resizes with the scroll surface.
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = MobilePreviewSurface()
        var identity = ""
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

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
    private let notice = UILabel()
    override init(frame: CGRect) {
        super.init(frame: frame)
        notice.font = .preferredFont(forTextStyle: .caption2)
        notice.textColor = .secondaryLabel; notice.backgroundColor = .secondarySystemBackground
        notice.layer.cornerRadius = 5; notice.clipsToBounds = true
        notice.text = "  HDR preview · this display is limited to SDR  "
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
