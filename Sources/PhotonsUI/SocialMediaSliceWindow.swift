import AppKit
import SwiftUI
import CoreImage
import PhotonsCore
import PhotonsExport
import PhotonsFileAccess
import PhotonsLocalization

@MainActor
public final class SocialMediaSliceWindowController: NSWindowController, NSWindowDelegate {
    let model: SocialMediaSliceModel
    public var onClose: (() -> Void)?

    public init(items: [ExportItem]) {
        model = SocialMediaSliceModel(items: items)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("slices.title")
        window.minSize = NSSize(width: 880, height: 680)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        model.window = window
        window.contentView = NSHostingView(rootView: SocialMediaSliceWorkspace(model: model))
        window.setFrameAutosaveName("PhotonsSocialMediaSlices")
        window.center()
        model.prepare()
    }

    public required init?(coder: NSCoder) { fatalError("no nib") }
    public func windowWillClose(_ notification: Notification) { model.close(); onClose?() }
}

@MainActor
final class SocialMediaSliceModel: ObservableObject {
    let items: [ExportItem]
    private let sourceAccess: [FileAccess]
    private var destinationAccess: FileAccess?
    weak var window: NSWindow?
    @Published var currentIndex = 0
    @Published var settings = SliceSettings()
    @Published var fills: [String: Double] = [:]
    @Published var sizes: [String: ImageSize] = [:]
    @Published var sourceErrors: [String: String] = [:]
    @Published var preview: CGImage?
    @Published var previewLoading = false
    @Published var preparing = true
    @Published var exporting = false
    @Published var guides = true
    @Published var status = L10n.tr("slices.loading")
    @Published var error: String?
    @Published var progress = 0.0
    @Published var outputParent: URL?
    @Published var lastOutputs: [URL] = []
    private let queue = DispatchQueue(label: "Photons.socialMediaSlices", qos: .userInitiated)
    private var cancellation = CancellationToken()
    private var previewCancellation = CancellationToken()
    private var previewGeneration = UUID()
    private var closed = false
    private var previewFrames: [String: DisplayImage] = [:]

    init(items: [ExportItem]) {
        sourceAccess = items.compactMap(\.sourceURL).map { FileAccessStore.shared.access(to: $0) }
        var resolved = items
        var sourceIndex = 0
        for index in resolved.indices where resolved[index].sourceURL != nil {
            resolved[index].sourceURL = sourceAccess[sourceIndex].url
            sourceIndex += 1
        }
        self.items = resolved
    }

    var current: ExportItem? { items.indices.contains(currentIndex) ? items[currentIndex] : nil }
    func settings(for item: ExportItem) -> SliceSettings {
        var value = settings
        value.fill = fills[item.id] ?? 90
        if let size = sizes[item.id], let limit = try? SliceLayout.maximumFill(size: size, settings: value) {
            value.fill = min(value.fill, limit)
        }
        return value
    }
    var layout: SliceLayout? {
        guard let item = current, let size = sizes[item.id] else { return nil }
        return try? SliceLayout.plan(size: size, settings: settings(for: item))
    }
    var currentError: String? {
        guard let item = current else { return nil }
        if let error = sourceErrors[item.id] { return error }
        guard let size = sizes[item.id] else { return nil }
        do { _ = try SliceLayout.plan(size: size, settings: settings(for: item)); return nil }
        catch { return error.localizedDescription }
    }
    var maximumFill: Double {
        guard let item = current, let size = sizes[item.id] else { return 98 }
        return (try? SliceLayout.maximumFill(size: size, settings: settings)) ?? 98
    }
    var currentFill: Double {
        get { current.map { settings(for: $0).fill } ?? 90 }
        set { if let item = current { fills[item.id] = min(maximumFill, max(10, newValue)) } }
    }
    var totalSlices: Int {
        items.reduce(0) { count, item in
            guard let size = sizes[item.id], let layout = try? SliceLayout.plan(size: size, settings: settings(for: item)) else { return count }
            return count + layout.count
        }
    }
    func estimatedFileSize(currentOnly: Bool = false) -> ExportFileSizeEstimate? {
        let selected = currentOnly ? current.map { [$0] } ?? [] : items
        guard !selected.isEmpty else { return nil }
        var estimates: [ExportFileSizeEstimate] = []
        for item in selected {
            let settings = settings(for: item)
            guard let size = sizes[item.id], let layout = try? SliceLayout.plan(size: size, settings: settings) else { return nil }
            let preset = ExportPreset(format: .jpeg, quality: Double(settings.quality) / 100, colorSpace: .sRGB,
                hdr: settings.dynamicRange == .hdr ? HDRExport(gainMap: .iso, halfSize: false) : nil,
                writeXMP: false)
            guard let estimate = ExportFileSizeEstimator.file(output: ImageSize(width: layout.tileWidth, height: layout.tileHeight), preset: preset) else { return nil }
            estimates.append(contentsOf: repeatElement(estimate, count: layout.count))
        }
        return .total(estimates)
    }

    var destination: URL? { current?.sourceURL.map { SocialMediaSliceExporter.outputDirectory(source: $0, parent: outputParent) } }

    func prepare() {
        let items = self.items, access = sourceAccess
        queue.async { [weak self] in
            var sizes: [String: ImageSize] = [:], errors: [String: String] = [:]
            withExtendedLifetime(access) {
                for item in items {
                    do {
                        guard let url = item.sourceURL else { throw UIExportError.noSourceFile(item.name) }
                        let native = try UIExportSource.size(at: url)
                        sizes[item.id] = (item.edit ?? .neutral).geometry.outputPixels(in: native)
                    } catch { errors[item.id] = error.localizedDescription }
                }
            }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.sizes = sizes; self.sourceErrors = errors; self.preparing = false
                self.status = L10n.tr("slices.ready", "\(items.count)")
                self.clampFills(); self.loadPreview()
            }
        }
    }

    func clampFills() {
        for item in items { fills[item.id] = settings(for: item).fill }
    }
    func select(_ index: Int) {
        guard items.indices.contains(index), !exporting else { return }
        currentIndex = index; loadPreview()
    }
    func loadPreview() {
        previewCancellation.cancel(); previewCancellation = CancellationToken()
        let token = previewCancellation
        let generation = UUID(); previewGeneration = generation
        preview = nil
        guard let item = current, sizes[item.id] != nil else { previewLoading = false; return }
        previewLoading = true
        let cached = previewFrames[item.id], mode = settings.dynamicRange, access = sourceAccess
        queue.async { [weak self] in
            do {
                if token.isCancelled { return }
                let result: (DisplayImage, CGImage) = try withExtendedLifetime(access) {
                    // One whole-photo projection for both HDR and SDR previews, just as in export.
                    let frame = try cached ?? UIExportRenderer.render(item: item,
                        preset: ExportPreset(format: .jpeg, longEdge: 1600, colorSpace: .sRGB, hdr: HDRExport()), native: nil)
                    let cg = try Self.previewImage(frame, mode: mode)
                    return (frame, cg)
                }
                DispatchQueue.main.async {
                    guard let self, !self.closed, self.previewGeneration == generation else { return }
                    // Bound memory when browsing a large selection.
                    if self.previewFrames.count >= 3 { self.previewFrames.removeAll() }
                    self.previewFrames[item.id] = result.0
                    self.preview = result.1; self.previewLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, !self.closed, self.previewGeneration == generation else { return }
                    self.sourceErrors[item.id] = error.localizedDescription; self.previewLoading = false
                }
            }
        }
    }

    nonisolated static func previewImage(_ image: DisplayImage, mode: SliceDynamicRange) throws -> CGImage {
        if mode == .sdr { return try Exporter.cgImage(image, bitDepth: 8) }
        guard let linear = image.linear else { throw SliceError.invalid("slices.error.noHDR") }
        let data = linear.rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: image.width * 8,
                         size: CGSize(width: image.width, height: image.height), format: .RGBAh,
                         colorSpace: HDREncoding.linearColorSpace(for: image.primaries))
        let space = CanvasPresenter.Storage.linear16.colorSpace!
        guard let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(ci, from: ci.extent,
            format: .RGBAh, colorSpace: space) else { throw UIExportError.noPixels("preview") }
        return cg
    }

    func chooseDirectory() {
        guard let window, !exporting else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = L10n.tr("slices.chooseDestination")
        panel.directoryURL = outputParent ?? current?.sourceURL?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try FileAccessStore.shared.rememberSelection(url)
                self.destinationAccess = FileAccessStore.shared.access(to: url)
                self.outputParent = self.destinationAccess?.url
            } catch { self.error = error.localizedDescription }
        }
    }

    func requestExport(currentOnly: Bool = false) {
        guard !preparing, !exporting, !closed else { return }
        let selected = currentOnly ? current.map { [$0] } ?? [] : items
        guard !selected.isEmpty else { return }
        do {
            let jobs: [SliceJob] = try selected.map { item in
                guard let source = item.sourceURL, let size = sizes[item.id] else {
                    throw UIExportError.noSourceFile(item.name)
                }
                let settings = self.settings(for: item)
                return SliceJob(item: item, settings: settings, layout: try SliceLayout.plan(size: size, settings: settings),
                    destination: SocialMediaSliceExporter.outputDirectory(source: source, parent: outputParent))
            }
            let paths = jobs.map { $0.destination.standardizedFileURL.path.lowercased() }
            guard Set(paths).count == paths.count else { throw SliceError.invalid("slices.error.duplicate") }
            let existing = jobs.filter { FileManager.default.fileExists(atPath: $0.destination.path) }
            if existing.isEmpty { run(jobs, replace: false); return }
            guard let window else { return }
            let alert = NSAlert()
            alert.messageText = L10n.tr("slices.replace.title")
            alert.informativeText = L10n.tr("slices.replace.detail", "\(existing.count)")
            alert.addButton(withTitle: L10n.tr("slices.replace"))
            alert.addButton(withTitle: L10n.tr("slices.cancel"))
            alert.beginSheetModal(for: window) { [weak self] response in
                if response == .alertFirstButtonReturn { self?.run(jobs, replace: true) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func run(_ jobs: [SliceJob], replace: Bool) {
        guard !exporting, !closed else { return }
        cancellation = CancellationToken()
        let token = cancellation, access = sourceAccess, outputAccess = destinationAccess
        exporting = true; progress = 0; error = nil; lastOutputs = []
        status = L10n.tr("slices.exporting", jobs.first?.item.name ?? "")
        queue.async { [weak self] in
            var outputs: [URL] = [], failures: [String] = [], completed = 0
            let total = jobs.reduce(0) { $0 + $1.layout.count }
            withExtendedLifetime((access, outputAccess)) {
                for job in jobs {
                    if token.isCancelled { break }
                    let start = completed
                    do {
                        try autoreleasepool {
                            DispatchQueue.main.async { self?.status = L10n.tr("slices.exporting", job.item.name) }
                            let frame = try UIExportRenderer.render(item: job.item,
                                preset: ExportPreset(format: .jpeg, longEdge: max(job.layout.photoWidth, job.layout.photoHeight),
                                    colorSpace: .sRGB, hdr: HDRExport()), native: nil, deferResampling: true)
                            if token.isCancelled { throw CancellationError() }
                            let group = try PreparedSlices(photo: frame, layout: job.layout, settings: job.settings)
                            try SocialMediaSliceExporter.write(group: group, source: job.item.sourceURL!, settings: job.settings,
                                to: job.destination, replace: replace, cancellation: token) { done, _ in
                                DispatchQueue.main.async { self?.progress = Double(start + done) / Double(total) }
                            }
                            outputs.append(job.destination)
                        }
                    } catch is CancellationError { break }
                    catch { failures.append("\(job.item.name)：\(error.localizedDescription)") }
                    completed += job.layout.count
                }
            }
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                self.exporting = false; self.lastOutputs = outputs
                self.progress = token.isCancelled ? self.progress : 1
                self.status = L10n.tr(token.isCancelled ? "slices.cancelled" : "slices.completed", "\(outputs.count)")
                if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
            }
        }
    }

    func cancel() { cancellation.cancel(); status = L10n.tr("slices.cancelling") }
    func close() { closed = true; cancellation.cancel(); previewCancellation.cancel(); previewGeneration = UUID() }
    func reveal() { NSWorkspace.shared.activateFileViewerSelecting(lastOutputs) }
}

private struct SliceJob {
    let item: ExportItem
    let settings: SliceSettings
    let layout: SliceLayout
    let destination: URL
}

struct SocialMediaSliceWorkspace: View {
    @ObservedObject var model: SocialMediaSliceModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                sidebar.frame(width: 294)
            }
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    ExportFileSizeLabel(estimate: model.estimatedFileSize(), identifier: "slices.estimatedSize")
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.exporting {
                    ProgressView(value: model.progress).frame(width: 150)
                    Button(L10n.tr("slices.cancel")) { model.cancel() }
                } else {
                    if model.items.count > 1 {
                        Button(L10n.tr("slices.exportCurrent")) { model.requestExport(currentOnly: true) }
                            .help(ExportFileSizeText.summary(model.estimatedFileSize(currentOnly: true)))
                            .disabled(model.preparing || model.layout == nil)
                    }
                    Button(L10n.tr("3fd47edce45b")) { model.window?.performClose(nil) }
                    Button(L10n.tr("slices.exportSelection", "\(model.items.count)")) { model.requestExport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.preparing || model.totalSlices == 0)
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)

        }
        .background(.regularMaterial)
        .alert(L10n.tr("slices.exportError"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.tr("slices.ok")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private var previewColumn: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.current?.sourceURL?.lastPathComponent ?? L10n.tr("slices.preview"))
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(metadata).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if model.items.count > 1 {
                    Button { model.select(model.currentIndex - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(model.currentIndex == 0 || model.exporting).help(L10n.tr("slices.previous"))
                    Text("\(model.currentIndex + 1) / \(model.items.count)").monospacedDigit().font(.caption)
                    Button { model.select(model.currentIndex + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(model.currentIndex == model.items.count - 1 || model.exporting).help(L10n.tr("slices.next"))
                }
            }.padding(20).frame(height: 76)
            GeometryReader { proxy in
                if let layout = model.layout, let image = model.preview {
                    let scale = min(max(1, proxy.size.width - 48) / CGFloat(layout.canvasWidth),
                                    max(1, proxy.size.height - 48) / CGFloat(layout.tileHeight))
                    SlicePreviewCanvas(image: image, layout: layout, scale: scale, tile: nil,
                                       guides: model.guides, hdr: model.settings.dynamicRange == .hdr)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.preparing || model.previewLoading {
                    ProgressView(L10n.tr("slices.loading")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(model.currentError ?? L10n.tr("slices.noPreview"))
                        .foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color(nsColor: .underPageBackgroundColor))
            HStack {
                Text(L10n.tr("slices.strip", "\(model.layout?.count ?? 0)")).font(.headline)
                Spacer()
                Toggle(L10n.tr("slices.guides"), isOn: $model.guides).toggleStyle(.checkbox)
            }.padding(.horizontal, 20).padding(.vertical, 13)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let layout = model.layout, let image = model.preview {
                        ForEach(0..<layout.count, id: \.self) { index in
                            VStack(spacing: 9) {
                                SlicePreviewCanvas(image: image, layout: layout, scale: 180 / CGFloat(layout.tileHeight),
                                    tile: index, guides: false, hdr: model.settings.dynamicRange == .hdr)
                                Text(String(format: "%03d", index + 1)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(20)
            }.frame(height: 245).background(Color(nsColor: .underPageBackgroundColor))
            Text(L10n.tr("slices.previewHint")).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }
    }

    private var metadata: String {
        guard let item = model.current, let size = model.sizes[item.id] else { return "—" }
        return "\(size.width) × \(size.height) px · " + L10n.tr("slices.selection", "\(model.items.count)")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.tr("slices.parameters")).font(.headline)
                Text(L10n.tr("slices.applySelection")).font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(height: 76)
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    field(L10n.tr("slices.orientation")) {
                        Picker("", selection: Binding(get: { model.settings.width > model.settings.height }, set: { landscape in
                            let edge = max(model.settings.width, model.settings.height)
                            model.settings.width = landscape ? edge : edge * 3 / 4
                            model.settings.height = landscape ? edge * 3 / 4 : edge
                            model.clampFills()
                        })) {
                            Text(L10n.tr("slices.portrait")).tag(false)
                            Text(L10n.tr("slices.landscape")).tag(true)
                        }.pickerStyle(.segmented)
                    }
                    field(L10n.tr("slices.resolution")) {
                        HStack(spacing: 3) {
                            ForEach(SliceSettings.resolutions, id: \.self) { edge in
                                let landscape = model.settings.width > model.settings.height
                                let selected = max(model.settings.width, model.settings.height) == edge
                                Button {
                                    model.settings.width = landscape ? edge : edge * 3 / 4
                                    model.settings.height = landscape ? edge * 3 / 4 : edge
                                    model.clampFills()
                                } label: {
                                    Text(verbatim: landscape ? "\(edge)\n× \(edge * 3 / 4)" : "\(edge * 3 / 4)\n× \(edge)")
                                        .font(.system(size: 12).monospacedDigit()).multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                        .background(selected ? Color.accentColor.opacity(0.25) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }.padding(3).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                    }
                    field(L10n.tr("slices.dynamicRange")) {
                        Picker("", selection: $model.settings.dynamicRange) {
                            Text("HDR").tag(SliceDynamicRange.hdr).disabled(!SliceDynamicRange.hdrAvailable)
                            Text("SDR").tag(SliceDynamicRange.sdr)
                        }.pickerStyle(.segmented).onChange(of: model.settings.dynamicRange) { _, _ in model.loadPreview() }
                        Text(L10n.tr(model.settings.dynamicRange == .hdr ? "slices.hdrHint" : "slices.sdrHint"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    field(L10n.tr("slices.resampling")) {
                        Picker("", selection: $model.settings.resampling) {
                            ForEach(SliceResampling.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.labelsHidden()
                    }
                    VStack(spacing: 7) {
                        HStack { Text(L10n.tr("slices.quality")); Spacer(); Text("\(model.settings.quality)").monospacedDigit() }
                        AdjustmentSlider(value: Binding(get: { Double(model.settings.quality) }, set: { model.settings.quality = Int($0) }), in: 60...100, step: 1)
                            .accessibilityLabel(L10n.tr("slices.quality"))
                    }
                    Divider()
                    Text(L10n.tr("slices.currentFrame")).font(.headline)
                    HStack {
                        Text(L10n.tr("slices.fill"))
                        Spacer()
                        TextField("", value: Binding(get: { model.currentFill }, set: { model.currentFill = $0 }),
                                  format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder).frame(width: 60)
                            .accessibilityLabel(L10n.tr("slices.fill"))
                        Text("%")
                    }
                    AdjustmentSlider(value: Binding(get: { model.currentFill }, set: { model.currentFill = $0 }),
                           in: 10...max(10.1, model.maximumFill), step: 0.1).accessibilityLabel(L10n.tr("slices.fill"))
                    Text(L10n.tr("slices.fillLimit", String(format: "%.1f", model.maximumFill)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("\(model.settings.width) × \(model.settings.height) px / " + L10n.tr("slices.tile")).font(.headline)
                    Text(L10n.tr("slices.count", "\(model.layout?.count ?? 0)", "\(model.totalSlices)"))
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 20)
            }.disabled(model.exporting || model.preparing)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.tr("slices.destination")).font(.headline)
                    Spacer()
                    Button(L10n.tr("slices.change")) { model.chooseDirectory() }.disabled(model.exporting)
                }
                Text(model.outputParent?.path ?? L10n.tr("slices.besideSource"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    .help(model.destination?.path ?? "")
                if model.outputParent != nil {
                    Button(L10n.tr("slices.useSource")) { model.outputParent = nil }.disabled(model.exporting)
                }
                Button(L10n.tr("slices.reveal"), systemImage: "folder") { model.reveal() }
                    .disabled(model.exporting || model.lastOutputs.isEmpty)
            }.padding(20)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(title); content().labelsHidden() }
    }
}

private struct SlicePreviewCanvas: View {
    let image: CGImage
    let layout: SliceLayout
    let scale: CGFloat
    let tile: Int?
    let guides: Bool
    let hdr: Bool
    var body: some View {
        let width = CGFloat(tile == nil ? layout.canvasWidth : layout.tileWidth) * scale
        let height = CGFloat(layout.tileHeight) * scale
        Color.white.frame(width: width, height: height)
        .overlay(alignment: .topLeading) {
            SlicePreviewImage(image: image, hdr: hdr)
                .frame(width: CGFloat(layout.photoWidth) * scale, height: CGFloat(layout.photoHeight) * scale)
                .offset(x: CGFloat(layout.x - (tile ?? 0) * layout.tileWidth) * scale, y: CGFloat(layout.y) * scale)
        }
        .overlay(alignment: .topLeading) {
            if guides && tile == nil {
                ForEach(1..<max(1, layout.count), id: \.self) { index in
                    Rectangle().fill(.black.opacity(0.4)).frame(width: 1, height: height)
                        .offset(x: CGFloat(index * layout.tileWidth) * scale)
                }
            }
        }.clipped()
            .overlay(Rectangle().stroke(.black.opacity(0.12), lineWidth: 1))
    }
}

private struct SlicePreviewImage: NSViewRepresentable {
    let image: CGImage
    let hdr: Bool
    func makeNSView(context: Context) -> SlicePreviewImageView { SlicePreviewImageView() }
    func updateNSView(_ view: SlicePreviewImageView, context: Context) { view.setImage(image, hdr: hdr) }
}

private final class SlicePreviewImageView: NSView {
    private let hdrView = PanoramaHDRPreviewView()
    private let sdrView = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(hdrView); addSubview(sdrView)
        sdrView.imageScaling = .scaleAxesIndependently
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("no nib") }
    func setImage(_ image: CGImage, hdr: Bool) {
        hdrView.isHidden = !hdr; sdrView.isHidden = hdr
        if hdr { hdrView.setImage(image) }
        else { sdrView.image = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)) }
    }
    override func layout() { super.layout(); hdrView.frame = bounds; sdrView.frame = bounds }
}
