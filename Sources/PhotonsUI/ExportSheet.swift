import AppKit
import Observation
import SwiftUI
import ImageIO
import PhotonsCore
import PhotonsCatalog
import PhotonsExport

// MARK: - export sheet (M5)
//
// The engine (`BatchExporter`, `ExportPreset`, `Exporter`) already existed and had no way in from
// the window; this file is the way in. Three pieces, in the order the data flows:
//
//   1. `UIExportRenderer` — one picture → `DisplayImage`, at the preset's long edge. Deliberately the
//      same shape as `photonsctl export batch`'s renderer (probe → crop → scale → decode → graph →
//      display): the D12 rule is "the export and the screen are one graph, the export just has no
//      viewport", and it stays true only while there is one implementation of it per surface.
//   2. `ExportSheetModel` — the draft `ExportPreset`, the per-item rows, the progress counter. The
//      view reads it; nothing else writes the settings.
//   3. `ExportSheetView` + `ExportSheetController` — SwiftUI in an `NSHostingController`, presented
//      as a real window sheet (no `NSAlert`, no hand-built AppKit form).
//
// Progress is measured, not animated: the render closure is called once per item by `BatchExporter`,
// so "已渲染 k/N" is a count of finished renders. Encoding per item follows the render, so the bar is
// honest about what it knows and says so (a row reads 已渲染 until the report replaces it with the
// file's real size and time).

// MARK: - renderer

public enum UIExportError: LocalizedError {
    case noSourceFile(String)
    case noPixels(String)

    public var errorDescription: String? {
        switch self {
        case .noSourceFile(let name): return "\(name): 没有源文件（资产指向的文件不存在）"
        case .noPixels(let name): return "\(name): 渲染器没有产出像素"
        }
    }
}

/// The window's export renderer: one decode + one render per picture, at the preset's scale.
///
/// `native` is the asset's own size when the catalog has it; otherwise the file is probed. The long
/// edge applies to the **cropped** picture (that is what the file will contain), exactly as
/// `photonsctl` does it, and `ExportSizing.scale` never upscales.
public enum UIExportRenderer {

    public static func render(item: ExportItem, preset: ExportPreset,
                              native: ImageSize?) throws -> DisplayImage {
        guard let url = item.sourceURL else { throw UIExportError.noSourceFile(item.name) }
        let edit = item.edit ?? .neutral
        let decoder = try RAWDecoder()

        let source: ImageSize
        if let native, native.width > 0, native.height > 0 {
            source = native
        } else {
            let probe = try decoder.probe(url)
            source = ImageSize(width: probe.nativeWidth, height: probe.nativeHeight)
        }

        let content = CropMath.outputSize(edit.geometry.renderCrop(source: source), in: source)
        let scale = preset.renderScale(content: content)
        let decodeScale = decodeScaleLadder(scale)
        let decoded = try decoder.decode(url, options: DecodeOptions(scale: decodeScale))

        let identity = "export|\(item.id)|v\(decoded.decoderVersion)"
            + String(format: "|s%.4f", decodeScale)
        // 2026-10-28 (P1b) — the export's own graph, with the pool policy a one-shot frame wants:
        //
        //   · `textureRetention: .none` — nothing is kept between frames, because there is no next
        //     frame. A 60 Mpx intermediate is 483 MB and the session is over when this returns.
        //   · `useCache: false` below — one frame cannot hit a cache it fills, so caching here only
        //     pins textures; the render loop gives each stage's input straight back to the pool
        //     instead, which is what holds the peak at two frame textures rather than eleven.
        //   · `releaseAllTextures()` on the way out — the atlas and any slot the frame did keep go
        //     back before the next picture in a batch decodes, so a 20-image batch no longer peaks at
        //     20 × the export's own working set.
        let graph = try RenderGraph(input: RenderInput(image: decoded, identity: identity,
                                                      sourceURL: url),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }
        let options = RenderOptions(canvas: nil,
                                    scale: scale / Double(decodeScale),
                                    display: DisplayOptions(primaries: preset.colorSpace,
                                                            bitDepth: preset.effectiveBitDepth,
                                                            headroom: 1),
                                    useCache: false,
                                    wantsPixels: true)
        let result = try graph.render(edit, options: options)
        guard let pixels = result.display else { throw UIExportError.noPixels(item.name) }
        return pixels
    }

    /// Smallest decode scale that still covers `target` — the same ladder the CLI uses, so a
    /// 512 px export of a 60 MP frame decodes at 0.125 on both paths instead of at 1.0 here.
    static func decodeScaleLadder(_ target: Double) -> Float {
        for s in [0.0625, 0.125, 0.25, 0.5, 1.0] as [Float] where Double(s) >= target - 1e-9 {
            return s
        }
        return 1.0
    }
}

// MARK: - rows

public struct ExportRow: Identifiable, Sendable {
    public enum State: String, Sendable {
        case pending
        case rendering
        case done
        case failed

        public var symbol: String {
            switch self {
            case .pending: return "circle.dotted"
            case .rendering: return "arrow.triangle.2.circlepath"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            }
        }
    }

    public var id: String
    public var name: String
    public var state: State = .pending
    public var detail: String = "等待"
    public var fileURL: URL?
    public var pixelSize: ImageSize?
    public var seconds: Double = 0
    public var warnings: [String] = []

    public init(id: String, name: String, state: State = .pending, detail: String = "等待",
                fileURL: URL? = nil, pixelSize: ImageSize? = nil, seconds: Double = 0,
                warnings: [String] = []) {
        self.id = id
        self.name = name
        self.state = state
        self.detail = detail
        self.fileURL = fileURL
        self.pixelSize = pixelSize
        self.seconds = seconds
        self.warnings = warnings
    }

    public var isFailure: Bool { state == .failed }
}

// MARK: - model

/// The sheet's state: the draft preset, the items, the per-image rows and the report.
///
/// `@Observable` so the SwiftUI leaf re-renders on a row change, `@MainActor` because every write
/// here lands in a view. The export itself runs on a worker (a 20-image batch must not freeze the
/// window) and hops back to this actor for each finished render and once at the end.
@MainActor
@Observable
public final class ExportSheetModel {

    public enum Phase: String, Sendable {
        case idle
        case running
        case finished
    }

    /// What the user is editing. Passed to `BatchExporter` verbatim at run time.
    public var preset: ExportPreset
    /// Where the files go. Chosen with a folder picker in the sheet; a sane default otherwise.
    public var outputDirectory: URL

    /// How many photos the sheet will export — set when it is presented, shown as "将导出 N 张".
    public var selectionCount: Int = 0

    public private(set) var phase: Phase = .idle
    public private(set) var total = 0
    public private(set) var rendered = 0
    public private(set) var rows: [ExportRow] = []
    public private(set) var report: BatchExportReport?
    public private(set) var errorText: String?
    public private(set) var startedAt: CFAbsoluteTime = 0
    public private(set) var finishedAt: CFAbsoluteTime = 0

    /// Closed by the view; wired by `ExportSheetController`.
    public var onClose: (() -> Void)?
    public var onReveal: (([URL]) -> Void)?
    public var onChooseDirectory: (() -> Void)?
    /// The 导出 button. The controller owns item assembly (it is the one with the session), so the
    /// view asks rather than reaching into the catalog itself.
    public var onExportRequest: (() -> Void)?

    public init(preset: ExportPreset = ExportSheetModel.defaultPreset,
                outputDirectory: URL = ExportSheetModel.defaultOutputDirectory) {
        self.preset = preset
        self.outputDirectory = outputDirectory
    }

    /// "网络 2048" — a JPEG that is safe to hand to anyone, not a TIFF of the original.
    ///
    /// `nonisolated`: a default argument is evaluated at the call site, which is not the main actor,
    /// and both of these are pure values.
    public nonisolated static var defaultPreset: ExportPreset {
        ExportPreset(name: "网络 2048", format: .jpeg, longEdge: 2048, quality: 0.85,
                     colorSpace: .sRGB, writeXMP: false, nameTemplate: "{name}")
    }

    public nonisolated static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photons 导出", isDirectory: true)
    }

    // MARK: derived

    public var progress: Double {
        total == 0 ? 0 : min(1, Double(rendered) / Double(total))
    }

    public var writtenCount: Int { rows.filter { $0.state == .done }.count }
    public var failedCount: Int { rows.filter { $0.state == .failed }.count }
    public var writtenURLs: [URL] { rows.compactMap { $0.state == .done ? $0.fileURL : nil } }

    public var elapsed: Double {
        let end = finishedAt == 0 ? CFAbsoluteTimeGetCurrent() : finishedAt
        return startedAt == 0 ? 0 : end - startedAt
    }

    public var summaryLine: String {
        switch phase {
        case .idle:
            return "将导出 \(selectionCount) 张 → \(preset.summary)"
        case .running:
            return String(format: "导出中… 已渲染 %d/%d · %.1f s", rendered, total, elapsed)
        case .finished:
            let failed = failedCount
            let base = String(format: "完成：%d 个文件", writtenCount)
            let tail = failed == 0 ? "" : "，\(failed) 张失败（其余已导出）"
            return base + tail + String(format: " · 共 %.2f s", elapsed)
        }
    }

    public var canRun: Bool {
        phase != .running && selectionCount > 0
            && !preset.nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: running

    /// Validate, then hand the batch to the engine on a worker. Returns immediately.
    ///
    /// - Parameter natives: asset id → the asset's own pixel size, when the catalog knows it. Items
    ///   without an entry are probed. This is what keeps the UI out of the decoder for sizes.
    public func run(items: [ExportItem], natives: [String: ImageSize] = [:]) {
        guard phase != .running else { return }
        guard !items.isEmpty else {
            errorText = "没有选中的照片"
            return
        }
        do {
            _ = try preset.validated()
        } catch {
            errorText = error.localizedDescription
            return
        }
        errorText = nil
        report = nil
        total = items.count
        rendered = 0
        selectionCount = items.count
        rows = items.map { ExportRow(id: $0.id, name: $0.name) }
        phase = .running
        startedAt = CFAbsoluteTimeGetCurrent()
        finishedAt = 0

        let preset = self.preset
        let directory = outputDirectory
        let render: (ExportItem, ExportPreset) throws -> DisplayImage = { item, preset in
            let image = try UIExportRenderer.render(item: item, preset: preset,
                                                    native: natives[item.id])
            // Called on a `BatchExporter` worker: the counter belongs to the main actor.
            DispatchQueue.main.async { [weak self] in self?.markRendered(item.id) }
            return image
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = BatchExporter.run(items: items, preset: preset,
                                           outputDirectory: directory,
                                           concurrency: BatchExporter.defaultConcurrency,
                                           render: render)
            DispatchQueue.main.async { self?.finish(with: report) }
        }
    }

    private func markRendered(_ id: String) {
        guard phase == .running else { return }
        rendered = min(total, rendered + 1)
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].state = .rendering
            rows[index].detail = "已渲染，写入中…"
        }
    }

    private func finish(with report: BatchExportReport) {
        self.report = report
        finishedAt = CFAbsoluteTimeGetCurrent()
        rendered = total
        rows = report.outcomes.map { outcome in
            var row = ExportRow(id: outcome.id, name: outcome.sourceName)
            row.fileURL = outcome.fileURL
            row.pixelSize = outcome.pixelSize
            row.seconds = outcome.seconds
            row.warnings = outcome.warnings
            if outcome.isSuccess {
                row.state = .done
                row.detail = [
                    outcome.pixelSize.map { "\($0.width)×\($0.height)" } ?? "—",
                    byteText(outcome.fileBytes),
                    String(format: "%.2f s", outcome.seconds),
                ].joined(separator: " · ")
                if !outcome.warnings.isEmpty {
                    row.detail += " · \(outcome.warnings.count) 条警告"
                }
            } else {
                row.state = .failed
                row.detail = "失败：\(outcome.error ?? "未知原因")"
            }
            return row
        }
        phase = .finished
    }

    public func revealInFinder() {
        let urls = writtenURLs
        guard !urls.isEmpty else { return }
        onReveal?(urls)
    }

    private func byteText(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return "\(bytes) B"
    }
}

// MARK: - view

/// The sheet's contents. A leaf: every control writes `model.preset` (the exact struct the batch
/// will use) and nothing else, so what the sheet shows is what the files get.
public struct ExportSheetView: View {
    @Bindable public var model: ExportSheetModel

    public init(model: ExportSheetModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            settings
            divider
            progressBlock
            results
            divider
            footer
        }
        .padding(18)
        .frame(width: 560, height: 640, alignment: .topLeading)
        .background(.regularMaterial)
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("导出")
                .font(.system(size: 14, weight: .bold))
            Text(model.phase == .idle
                 ? "将导出 \(model.selectionCount) 张"
                 : model.summaryLine)
                .font(.system(size: 11))
                .foregroundStyle(model.errorText == nil ? AnyShapeStyle(.secondary)
                                                        : AnyShapeStyle(Color.red))
                .fixedSize(horizontal: false, vertical: true)
            Text(model.preset.summary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: settings (bound straight to ExportPreset)

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                labelled("格式") {
                    Picker("", selection: $model.preset.format) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Text(format.rawValue.uppercased()).tag(format)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)
                    .disabled(model.phase == .running)
                }
                labelled("长边") {
                    Picker("", selection: longEdgeBinding) {
                        Text("原尺寸").tag(0)
                        ForEach([512, 1024, 2048, 4096], id: \.self) { edge in
                            Text("\(edge) px").tag(edge)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)
                    .disabled(model.phase == .running)
                }
                labelled("色彩") {
                    Picker("", selection: $model.preset.colorSpace) {
                        Text("sRGB").tag(OutputPrimaries.sRGB)
                        Text("Display P3").tag(OutputPrimaries.displayP3)
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 110)
                    .disabled(model.phase == .running)
                }
            }

            HStack(spacing: 10) {
                labelled("质量") {
                    HStack(spacing: 6) {
                        Slider(value: $model.preset.quality, in: 0.1 ... 1.0)
                            .controlSize(.small)
                            .frame(width: 120)
                            .disabled(model.phase == .running || !model.preset.format.supportsQuality)
                        Text(String(format: "%.2f", model.preset.quality))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(model.preset.format.supportsQuality
                                             ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    }
                }
                Toggle(isOn: $model.preset.writeXMP) {
                    Text("写入 XMP")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.phase == .running)
            }

            HStack(spacing: 10) {
                labelled("命名") {
                    TextField("{name} / {date} / {seq} / {rating}", text: $model.preset.nameTemplate)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 230)
                        .disabled(model.phase == .running)
                }
                Toggle(isOn: sixteenBitBinding) {
                    Text("16 位")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.phase == .running || !model.preset.format.supports16Bit)
                .help(model.preset.format.supports16Bit
                      ? "16 位/通道（JPEG、AVIF 只能 8 位）"
                      : "\(model.preset.format.rawValue.uppercased()) 只能 8 位/通道")
            }

            HStack(spacing: 8) {
                labelled("目录") {
                    Text(model.outputDirectory.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("选择…") { model.onChooseDirectory?() }
                    .controlSize(.mini)
                    .disabled(model.phase == .running)
            }
        }
    }

    // MARK: progress + results

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.phase == .running {
                ProgressView(value: model.progress)
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            }
            if let error = model.errorText {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var results: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.rows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.state.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(color(for: row.state))
                            .frame(width: 12)
                        Text(row.name)
                            .font(.system(size: 10, weight: row.isFailure ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(row.isFailure ? AnyShapeStyle(Color.red)
                                                           : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(row.isFailure ? Color.red.opacity(0.08) : Color.clear)
                    )
                }
                if model.rows.isEmpty {
                    Text("还没有导出。选择照片，点“导出”。")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if model.phase == .finished && model.writtenCount > 0 {
                Button("在 Finder 中显示") { model.revealInFinder() }
                    .controlSize(.small)
            }
            Spacer(minLength: 8)
            Button("关闭") { model.onClose?() }
                .controlSize(.small)
            Button(model.phase == .finished ? "再导出一次" : "导出") {
                // The controller owns item assembly (it has the session); this is the UI door.
                model.onExportRequest?()
            }
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canRun)
        }
    }

    // MARK: building blocks

    private func labelled<Content: View>(_ title: String,
                                         @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func color(for state: ExportRow.State) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .red
        case .rendering: return .accentColor
        case .pending: return .secondary
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }

    private var longEdgeBinding: Binding<Int> {
        Binding(get: { model.preset.longEdge ?? 0 },
                set: { model.preset.longEdge = $0 <= 0 ? nil : $0 })
    }

    private var sixteenBitBinding: Binding<Bool> {
        Binding(get: { model.preset.bitDepth == 16 },
                set: { model.preset.bitDepth = $0 ? 16 : 8 })
    }
}

// MARK: - presentation

/// SwiftUI in an `NSHostingController`, shown as a window sheet.
///
/// The window (not the view) is the sheet: `beginSheet` gives it the titlebar-less, dimmed-parent
/// presentation macOS expects, and closing it is one `endSheet`. The controller is also what the
/// menu action and `--ui-smoke` talk to, so "present the sheet" and "run an export" are the same
/// code the 导出… item takes.
@MainActor
public final class ExportSheetController: NSObject {

    public let model: ExportSheetModel
    public let session: CatalogSession
    private let hosting: NSHostingController<ExportSheetView>
    public private(set) var sheetWindow: NSWindow?

    /// The batch this sheet will write, captured when the sheet opens.
    ///
    /// Captured — not re-read at click time — because "将导出 3 张" is a promise: if the selection
    /// moves under a sheet that already says 3, exporting something else would be a lie (and the
    /// grid does move it: presenting a sheet takes key focus, and a collection view that re-syncs
    /// its own selection writes the model). `refreshItems()` exists for a caller that wants to
    /// re-capture deliberately.
    public private(set) var items: [ExportItem] = []
    private var natives: [String: ImageSize] = [:]

    public init(session: CatalogSession, outputDirectory: URL? = nil) {
        self.session = session
        let model = ExportSheetModel(outputDirectory: outputDirectory
                                     ?? ExportSheetModel.defaultOutputDirectory)
        self.model = model
        self.hosting = NSHostingController(rootView: ExportSheetView(model: model))
        super.init()

        model.onClose = { [weak self] in self?.dismiss() }
        model.onReveal = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
        model.onChooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.onExportRequest = { [weak self] in self?.runExport() }
    }

    public var isPresented: Bool { sheetWindow?.sheetParent != nil }

    // MARK: present / dismiss

    public func present(in parent: NSWindow) {
        refreshItems()
        model.selectionCount = items.count
        if let existing = sheetWindow, existing.sheetParent != nil {
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = "导出 \(model.selectionCount) 张照片"
        window.contentViewController = hosting
        window.isReleasedWhenClosed = false
        parent.beginSheet(window)
        sheetWindow = window
    }

    public func dismiss() {
        guard let window = sheetWindow else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    // MARK: run

    /// Assemble the items from the live selection and hand them to the model.
    ///
    /// The document comes from the catalog (`session.exportItems`), not from a side file, and the
    /// pixel size from the asset row when it exists — one probe less per picture.
    public func runExport() {
        guard !items.isEmpty else {
            model.selectionCount = 0
            model.run(items: [])
            return
        }
        model.selectionCount = items.count
        model.run(items: items, natives: natives)
    }

    /// Re-capture what the sheet will write (a new selection, a new document).
    public func refreshItems() {
        let assets = session.exportableSelection
        items = session.exportItems(for: assets)
        var sizes: [String: ImageSize] = [:]
        for asset in assets {
            if let w = asset.width, let h = asset.height, w > 0, h > 0 {
                sizes[asset.id] = ImageSize(width: w, height: h)
            }
        }
        natives = sizes
        model.selectionCount = items.count
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "导出到哪里"
        panel.directoryURL = model.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.outputDirectory = url
    }
}
