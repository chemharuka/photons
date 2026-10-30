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

        let content = edit.geometry.outputPixels(in: source)
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
        // 113 — HDR export is **one** render of the HDR frame; the SDR base is a projection of it.
        //
        // The order used to be the other way round (SDR render first, then a second `linearOutput`
        // pass), which meant the gain map's ratio was measured against a picture that had already
        // been hard-cut at display white, and would have split into two unrelated histories the
        // moment the SDR side grew a real tone map (112). Now both halves come from one frame.
        if preset.isHDR {
            let hdr = RenderOptions(canvas: nil,
                                    scale: scale / Double(decodeScale),
                                    display: DisplayOptions(primaries: preset.colorSpace,
                                                            bitDepth: preset.effectiveBitDepth,
                                                            headroom: 1,
                                                            linearOutput: true),
                                    useCache: false,
                                    wantsPixels: true)
            guard let frame = try graph.render(edit, options: hdr).display else {
                throw UIExportError.noPixels(item.name)
            }
            // `s4_display_linear` already applied the primaries matrix, so this is tone map + OETF
            // only. 112 — the SDR base gets the same `-r`/`-R` global roll-off toGainMapHDR uses.
            return LinearPixels(frame).displaySDR(bitDepth: preset.effectiveBitDepth,
                                                  toneMap: .global)
        }
        // 109 §3 — SDR with the global tone map takes the same linear exit the HDR base uses, then
        // rolls the highlights into 1 before the OETF. `.none` stays on the historical S4 path below,
        // which is the byte-identical hard clamp.
        if preset.appliesSDRToneMap {
            let linearOptions = RenderOptions(canvas: nil,
                                              scale: scale / Double(decodeScale),
                                              display: DisplayOptions(primaries: preset.colorSpace,
                                                                      bitDepth: preset.effectiveBitDepth,
                                                                      headroom: 1,
                                                                      linearOutput: true),
                                              useCache: false,
                                              wantsPixels: true)
            guard let frame = try graph.render(edit, options: linearOptions).display else {
                throw UIExportError.noPixels(item.name)
            }
            return LinearPixels(frame).displaySDR(bitDepth: preset.effectiveBitDepth,
                                                  toneMap: .global)
        }
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
        case skipped
        case cancelled

        public var symbol: String {
            switch self {
            case .pending: return "circle.dotted"
            case .rendering: return "arrow.triangle.2.circlepath"
            case .done: return "checkmark.circle.fill"
            case .failed: return "xmark.octagon.fill"
            case .skipped: return "arrow.uturn.forward.circle"
            case .cancelled: return "minus.circle"
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

/// 109 §1 — the two halves of the gain-map row. `HDRExport.GainMap` is the storage spelling; these
/// are what the user picks. Apple's gain map is monochrome by construction, so RGB + Apple is not a
/// state the sheet can enter (picking one side locks the other).
public enum GainMapColorModel: String, Sendable, CaseIterable {
    case rgb
    case mono

    public var displayName: String {
        switch self {
        case .rgb: return "RGB"
        case .mono: return "黑白"
        }
    }
}

public enum GainMapVersion: String, Sendable, CaseIterable {
    case iso
    case apple

    public var displayName: String {
        switch self {
        case .iso: return "ISO"
        case .apple: return "Apple"
        }
    }
}

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

    /// 099: the sections, in Lightroom's order, as data — the view and its test read the same list.
    public static let sectionTitles = ["位置", "文件命名", "文件设置", "图像尺寸",
                                       "输出锐化", "元数据", "导出"]

    /// What the user is editing. Passed to `BatchExporter` verbatim at run time.
    ///
    /// 161 §4 — this is the one `touch()` entry the whole sheet goes through: a write here (or to
    /// `outputDirectory` / `selectionCount` below) while the previous run's 完成 report is still on
    /// screen returns the sheet to 「将导出 N 张 → …」. The controls do not each implement that.
    public var preset: ExportPreset {
        didSet { resetFinishedReportAfterConfigurationChange() }
    }
    /// Where the files go. Chosen with a folder picker in the sheet; a sane default otherwise.
    public var outputDirectory: URL {
        didSet { resetFinishedReportAfterConfigurationChange() }
    }

    /// Named presets, one file each (see `ExportPresetStore`).
    public let presetStore: ExportPresetStore
    public private(set) var presetNames: [String] = []
    public private(set) var presetError: String?
    public private(set) var cancellation: CancellationToken?

    /// 109 §2 — the UTIs this machine's ImageIO can write. Injected by the tests so "AVIF is not
    /// offered without an encoder" can be asserted on a machine that happens to have one.
    public let writableUTIs: Set<String>

    /// The format row: only formats with a real encoder, in the enum's stable order.
    public var availableFormats: [ExportFormat] {
        ExportFormat.available(writableUTIs: writableUTIs)
    }

    /// 161 §5 — the last draft the user actually exported, and the close-time writer. `draftStore` is
    /// injected (`UserDefaults.standard` in the app) so the tests can run against an in-memory store.
    public let draftStore: ExportDraftPersistence.Store
    /// Set when the remembered blob could not be decoded. The bad blob is removed; the defaults are
    /// used, and the notice is how that is *recorded* rather than silently forgotten.
    public private(set) var draftNotice: String?
    private var lastSuccessfulDraft: ExportDraftPersistence.Draft?
    private var pendingRunDraft: ExportDraftPersistence.Draft?

    /// How many photos the sheet will export — set when it is presented, shown as "将导出 N 张".
    public var selectionCount: Int = 0 {
        didSet { resetFinishedReportAfterConfigurationChange() }
    }

    /// `internal(set)` so the footer/layout tests can put the model in a phase without starting a
    /// real render; the app only writes it in `run`/`cancel`/`finish`.
    public internal(set) var phase: Phase = .idle
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

    /// - Parameters:
    ///   - preset: an explicit draft. `nil` means "use the remembered draft, or the factory default".
    ///   - outputDirectory: an explicit destination. `nil` means "the remembered one, or the default".
    ///   - draftStore: the `UserDefaults`-shaped store; injected by tests.
    ///
    /// 161 §5: the sheet is created once per window and opened repeatedly, so its first values are
    /// the **last draft that was exported** (or saved on close), not a hard-coded 2048 long edge.
    public init(preset: ExportPreset? = nil,
                outputDirectory: URL? = nil,
                presetStore: ExportPresetStore? = nil,
                writableUTIs: Set<String>? = nil,
                draftStore: ExportDraftPersistence.Store? = nil) {
        let draftStore = draftStore ?? UserDefaults.standard
        self.draftStore = draftStore

        let recalled = ExportDraftPersistence.recall(from: draftStore)
        var notice: String?
        var remembered: ExportDraftPersistence.Draft?
        switch recalled {
        case .missing:
            break
        case .draft(let draft):
            remembered = draft
        case .unreadable:
            // 161 §5 M2 — never crash and never silently keep a blob we cannot read. Remove it and
            // say so; the next successful export writes a clean one.
            ExportDraftPersistence.clear(in: draftStore)
            notice = "导出设置记忆已损坏，已恢复默认设置"
        }

        let startingPreset = preset ?? remembered?.preset ?? Self.defaultPreset
        self.preset = startingPreset
        self.hdrPreferredEnabled = startingPreset.hdr?.enabled ?? true
        self.outputDirectory = outputDirectory ?? remembered?.directoryURL
            ?? Self.defaultOutputDirectory
        self.writableUTIs = writableUTIs ?? ExportFormat.writableUTIs
        let store = presetStore ?? ExportPresetStore()
        self.presetStore = store
        self.presetNames = store.names
        self.draftNotice = notice
    }

    /// The factory draft (161 §1/§9): the picture's **own** size, quality 0.85, HEIC + HDR gain map +
    /// P3. The sheet is the one surface that owns this draft, so the values live here rather than in
    /// `ExportPreset()` (whose JPEG default is the CLI/API default).
    ///
    /// `nonisolated`: a default argument is evaluated at the call site, which is not the main actor,
    /// and both of these are pure values.
    public nonisolated static var defaultPreset: ExportPreset {
        ExportPreset(name: "默认", format: .heic, quality: 0.85,
                     bitDepth: 8, colorSpace: .displayP3, sdrToneMapping: .global,
                     hdr: HDRExport(gainMap: .iso), writeXMP: false, nameTemplate: "{name}",
                     sizingMode: ExportSizingMode.none)
    }

    /// 161 §1 — the old factory draft, still selectable in the preset popup. It has its own name and
    /// purpose (a HEIC safe to hand to anyone), so it keeps its 2048 long edge and 0.95 quality; only
    /// the **default** moved.
    public nonisolated static var network2048Preset: ExportPreset {
        ExportPreset(name: "网络 2048", format: .heic, longEdge: 2048, quality: 0.95,
                     bitDepth: 8, colorSpace: .displayP3, sdrToneMapping: .global,
                     hdr: HDRExport(gainMap: .iso), writeXMP: false, nameTemplate: "{name}")
    }

    /// Built-in presets shown beside the user's saved files. They are read-only: saving/deleting only
    /// ever touches `presetStore`'s directory.
    public nonisolated static var builtInPresets: [ExportPreset] { [network2048Preset] }

    public nonisolated static var builtInPresetNames: [String] { builtInPresets.compactMap(\.name) }

    /// The popup's rows: built-ins first, then the saved files that are not already named there.
    public var presetPickerNames: [String] {
        var names = Self.builtInPresetNames
        for name in presetNames where !names.contains(name) { names.append(name) }
        return names
    }

    /// A built-in is read-only only while there is no saved file of the same name; a user who saved
    /// their own 网络 2048 owns that file and may delete it.
    public func isBuiltInPreset(_ name: String) -> Bool {
        Self.builtInPresetNames.contains(name) && !presetNames.contains(name)
    }

    public nonisolated static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Photons 导出", isDirectory: true)
    }

    // MARK: HDR (106)

    /// The user's last HDR checkbox choice. Kept here (not in a fresh `@State`) so a format round
    /// trip — HEIC → JPEG → HEIC — restores what they picked instead of resetting to `true`.
    public private(set) var hdrPreferredEnabled: Bool

    /// What the checkbox shows. Non-HEIC is always off (the row is greyed out there too).
    public var hdrEnabled: Bool {
        guard preset.format == .heic else { return false }
        return preset.hdr?.enabled ?? hdrPreferredEnabled
    }

    public var hdrGainMap: HDRExport.GainMap {
        get { preset.hdr?.gainMap ?? .iso }
        set { updateHDR { $0.gainMap = newValue } }
    }

    public var hdrHalfSize: Bool {
        get { preset.hdr?.halfSize ?? true }
        set { updateHDR { $0.halfSize = newValue } }
    }

    /// 109 §1 — which half of the gain-map row is highlighted. `.iso` is the only RGB spelling, so
    /// RGB and `.mono`/`.apple` are the two sides of the same three-value enum.
    public var gainMapColorModel: GainMapColorModel {
        preset.hdr?.gainMap == .iso ? .rgb : .mono
    }

    /// `.apple` is the only Apple spelling; both ISO values read as version ISO.
    public var gainMapVersion: GainMapVersion {
        preset.hdr?.gainMap == .apple ? .apple : .iso
    }

    /// Apple's gain map is single-channel, so choosing RGB locks the version to ISO; choosing Apple
    /// locks the model to 黑白. The sheet never shows an illegal pair, and the preset can never hold
    /// one either.
    public func setGainMapColorModel(_ model: GainMapColorModel) {
        switch model {
        case .rgb:
            updateHDR { $0.gainMap = .iso }
        case .mono:
            updateHDR { $0.gainMap = gainMapVersion == .apple ? .apple : .mono }
        }
    }

    public func setGainMapVersion(_ version: GainMapVersion) {
        updateHDR { hdr in
            switch version {
            case .apple:
                hdr.gainMap = .apple
            case .iso:
                hdr.gainMap = gainMapColorModel == .rgb ? .iso : .mono
            }
        }
    }

    /// 109 §1 — HDR on shows the gain-map row and hides tone mapping; HDR off is the reverse.
    public var showsGainMapRows: Bool { hdrEnabled }
    public var showsToneMappingRow: Bool { !hdrEnabled }

    /// 109 §3 — only an SDR export consults this.
    public var sdrToneMapping: SDRToneMapping {
        get { preset.sdrToneMapping }
        set { preset.sdrToneMapping = newValue }
    }

    public func setSDRToneMapping(_ value: SDRToneMapping) {
        preset.sdrToneMapping = value
    }

    /// 109 §1 / 108 — the bit-depth row's legal values for the current format.
    public var bitDepths: [Int] { preset.format.bitDepths }

    public func selectBitDepth(_ depth: Int) {
        guard bitDepths.contains(depth) else { return }
        preset.bitDepth = depth
    }

    /// The 文件设置 picker's door: going non-HEIC turns HDR off (and `validated()` would reject it
    /// anyway), coming back re-applies the remembered choice. A depth the new container cannot store
    /// is clamped instead of left behind as an invisible illegal value.
    public func selectFormat(_ format: ExportFormat) {
        guard availableFormats.contains(format) else { return }
        preset.format = format
        preset.bitDepth = format.clampedBitDepth(preset.bitDepth)
        applyHDR(enabled: format == .heic ? hdrPreferredEnabled : false)
    }

    /// The HDR checkbox. Writes through to the preset the batch will use.
    public func setHDR(_ enabled: Bool) {
        hdrPreferredEnabled = enabled
        applyHDR(enabled: enabled)
    }

    private func applyHDR(enabled: Bool) {
        updateHDR { $0.enabled = enabled }
    }

    private func updateHDR(_ body: (inout HDRExport) -> Void) {
        var hdr = preset.hdr ?? HDRExport(enabled: preset.format == .heic)
        body(&hdr)
        preset.hdr = hdr
    }

    // MARK: sizing (161 §1–§3)

    /// The 尺寸模式 popup's one write path. Setting the mode is not enough on its own: the old draft
    /// carries a `longEdge`, and `ExportPreset.renderScale` still honours it in `.none` mode. That was
    /// the "选原尺寸却出 2048" break — the popup wrote `.none`, but the renderer kept the 2048 ceiling.
    /// Clearing it here makes `原尺寸` mean scale 1 for the whole path (prediction, render, batch).
    public func selectSizingMode(_ mode: ExportSizingMode) {
        preset.sizingMode = mode
        switch mode {
        case .none:
            preset.longEdge = nil
        case .longEdge:
            if preset.longEdge == nil { preset.longEdge = 2048 }
        case .percent:
            if preset.percent == nil { preset.percent = 100 }
        }
    }

    /// The exact struct handed to `BatchExporter`. A defensive normalisation as well as the panel
    /// write: a saved/legacy preset with `sizingMode == .none` *and* a stale `longEdge` must not
    /// render at 2048 just because it did not pass through `selectSizingMode`.
    public var effectivePreset: ExportPreset {
        var out = preset
        if out.sizingMode == .none { out.longEdge = nil }
        return out
    }

    /// What the output pixels will be for a crop of `native`. The sheet's prediction and the batch's
    /// render both go through `ExportSizing`, so this is a forecast, not a restatement.
    public func predictedSizeText(native: ImageSize) -> String {
        let preset = effectivePreset
        let size = ExportSizing.outputSize(content: native,
                                           scale: preset.renderScale(content: native))
        return "\(size.width)×\(size.height)"
    }

    // MARK: status line (161 §4)

    /// Every configuration change lands here (through `preset`/`outputDirectory`/`selectionCount`'s
    /// `didSet`). It only acts on a finished report: during `.running` the report is live and must not
    /// be cleared, and an untouched sheet keeps its 完成 line.
    private func resetFinishedReportAfterConfigurationChange() {
        guard phase == .finished else { return }
        phase = .idle
        total = 0
        rendered = 0
        rows = []
        report = nil
        errorText = nil
        startedAt = 0
        finishedAt = 0
        cancellation = nil
    }

    // MARK: derived

    public var progress: Double {
        total == 0 ? 0 : min(1, Double(rendered) / Double(total))
    }

    public var writtenCount: Int { rows.filter { $0.state == .done }.count }
    public var failedCount: Int { rows.filter { $0.state == .failed }.count }
    public var skippedCount: Int { rows.filter { $0.state == .skipped }.count }
    public var cancelledCount: Int { rows.filter { $0.state == .cancelled }.count }
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
            var parts = [String(format: "完成：%d 个文件", writtenCount)]
            if skippedCount > 0 { parts.append("跳过 \(skippedCount)") }
            if cancelledCount > 0 { parts.append("取消 \(cancelledCount)") }
            if failedCount > 0 { parts.append("失败 \(failedCount)") }
            return parts.joined(separator: "，") + String(format: " · 共 %.2f s", elapsed)
        }
    }

    public var canRun: Bool {
        phase != .running && selectionCount > 0
            && !preset.nameTemplate.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 161 §7 — the footer as data. The view builds its buttons from this list, so "取消 only while
    /// running, 关闭 every other phase" is one rule the test can assert without an AppKit leaf
    /// (SwiftUI's buttons are drawn by the framework and are not `NSButton`s under `swift test`).
    public struct FooterItem: Identifiable, Equatable {
        public enum Kind: String, Equatable { case reveal, close, cancel, export }
        public var kind: Kind
        public var title: String
        public var isEnabled: Bool
        public var id: Kind { kind }
    }

    public var footerItems: [FooterItem] {
        if phase == .running {
            // 关闭 is not built at all while files are being written: hiding the sheet would not
            // stop the batch ("关了但还在写文件").
            return [FooterItem(kind: .cancel, title: "取消", isEnabled: true),
                    FooterItem(kind: .export, title: "导出", isEnabled: false)]
        }
        var items: [FooterItem] = []
        if phase == .finished {
            if writtenCount > 0 {
                items.append(FooterItem(kind: .reveal, title: "在 Finder 中显示", isEnabled: true))
            }
            // §7's finished order: 在 Finder 中显示 → 再导出一次 → 关闭.
            items.append(FooterItem(kind: .export, title: "再导出一次", isEnabled: canRun))
            items.append(FooterItem(kind: .close, title: "关闭", isEnabled: true))
        } else {
            items.append(FooterItem(kind: .close, title: "关闭", isEnabled: true))
            items.append(FooterItem(kind: .export, title: "导出", isEnabled: canRun))
        }
        return items
    }

    /// The footer's one line: the empty prompt, live progress, or the finished report. Errors win —
    /// they are why a run stopped, and the footer is where the user is looking after pressing 导出.
    public var footerStatus: String {
        if let errorText { return errorText }
        if phase == .idle, rows.isEmpty { return "还没有导出。选择照片，点“导出”。" }
        return summaryLine
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
        let token = CancellationToken()
        cancellation = token

        // Snapshot at the click, not at completion: the sheet is disabled during the run, and the
        // rows' sizes must describe the preset the files were actually written with.
        let preset = effectivePreset
        let directory = outputDirectory
        // 161 §5 — what a successful run remembers. The draft is the *run's* snapshot, so a field
        // the user changes after the report appears cannot leak into "last used".
        pendingRunDraft = ExportDraftPersistence.Draft(preset: preset, outputDirectory: directory)
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
                                           cancel: token,
                                           render: render)
            DispatchQueue.main.async { self?.finish(with: report) }
        }
    }

    /// The 取消 button. In-flight renders finish; queued items come back as cancelled.
    public func cancel() {
        guard phase == .running else { return }
        cancellation?.cancel()
    }

    private func markRendered(_ id: String) {
        guard phase == .running else { return }
        rendered = min(total, rendered + 1)
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].state = .rendering
            rows[index].detail = "已渲染，写入中…"
        }
    }

    /// Internal (not private) so the persistence/status tests can feed it a real `BatchExporter` report
    /// without a RAW fixture; the app reaches it from the worker's main-queue hop.
    func finish(with report: BatchExportReport) {
        self.report = report
        finishedAt = CFAbsoluteTimeGetCurrent()
        cancellation = nil
        rendered = report.outcomes.filter { !$0.cancelled }.count
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
            } else if outcome.cancelled {
                row.state = .cancelled
                row.detail = "已取消"
            } else if outcome.skipped {
                row.state = .skipped
                row.detail = "跳过：目标文件已存在"
            } else {
                row.state = .failed
                row.detail = "失败：\(outcome.error ?? "未知原因")"
            }
            return row
        }
        phase = .finished

        // 161 §5 — write the draft once, on a run that actually produced files. A failed or fully
        // cancelled run leaves the previous "last used" draft alone (M3).
        if writtenCount > 0 {
            // `pendingRunDraft` is the run's own snapshot in production. The fallback keeps the
            // persistence tests honest when they feed `finish` a report directly.
            let draft = pendingRunDraft ?? ExportDraftPersistence.Draft(
                preset: effectivePreset, outputDirectory: outputDirectory)
            lastSuccessfulDraft = draft
            ExportDraftPersistence.save(preset: draft.preset,
                                        outputDirectory: draft.directoryURL,
                                        to: draftStore)
        }
        pendingRunDraft = nil
    }

    /// 161 §5 — the second write point: when the sheet closes. It saves the **last exported** draft
    /// (M3), not whatever the user typed after the report appeared and did not export. A sheet that
    /// never exported anything saves its current draft, which is what makes a preference survive a
    /// close without a run.
    public func saveDraftOnClose() {
        let draft = lastSuccessfulDraft ?? ExportDraftPersistence.Draft(
            preset: effectivePreset, outputDirectory: outputDirectory)
        ExportDraftPersistence.save(preset: draft.preset,
                                    outputDirectory: draft.directoryURL,
                                    to: draftStore)
    }

    public func revealInFinder() {
        let urls = writtenURLs
        guard !urls.isEmpty else { return }
        onReveal?(urls)
    }

    // MARK: presets

    public func refreshPresets() {
        presetStore.refresh()
        presetNames = presetStore.names
    }

    public func loadPreset(named name: String) {
        do {
            preset = try presetStore.load(named: name)
            hdrPreferredEnabled = preset.hdr?.enabled ?? true
            if preset.format == .heic { applyHDR(enabled: hdrPreferredEnabled) }
            presetError = nil
            return
        } catch {
            // A built-in has no file; fall back to it by name before surfacing the file error.
            if let builtIn = Self.builtInPresets.first(where: { $0.name == name }) {
                preset = builtIn
                hdrPreferredEnabled = builtIn.hdr?.enabled ?? true
                presetError = nil
                return
            }
            presetError = error.localizedDescription
        }
    }

    @discardableResult
    public func savePreset(named name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presetError = "预设名称不能为空"
            return false
        }
        do {
            preset = try presetStore.save(preset, named: name)
            presetNames = presetStore.names
            presetError = nil
            return true
        } catch {
            presetError = error.localizedDescription
            return false
        }
    }

    public func deletePreset(named name: String) {
        do {
            try presetStore.delete(named: name)
            presetNames = presetStore.names
            presetError = nil
        } catch {
            presetError = error.localizedDescription
        }
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

    @State private var selectedPreset = ""
    @State private var showingSavePreset = false
    @State private var newPresetName = ""

    public init(model: ExportSheetModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Form {
                locationSection
                namingSection
                fileSection
                sizeSection
                sharpenSection
                metadataSection
                exportSection
            }
            .formStyle(.grouped)
            .disabled(model.phase == .running)
            // 161 §6 — the scroll region is the one that eats the remaining height. Before this the
            // form only had `layoutPriority(2)` and the (empty) results region kept a 140 pt floor,
            // so the sheet showed a large blank strip between the scroll view and the footer. The
            // form still scrolls: its seven sections want ~1078 pt, more than the sheet can hold.
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
            .scrollIndicators(.visible)
            .background(ExportLayoutProbeHost(kind: .form))
            // Only built when there is something to show: an empty results region would be exactly
            // the blank gap §6 is about. With rows it takes a bounded height and the form shrinks.
            if !model.rows.isEmpty {
                results
            }
            footer
        }
        .padding(18)
        // 620×900 is the sheet's size (`ExportSheetController.present`): tall enough for all seven
        // sections plus a results region that still has room to grow. Not content height — the form
        // must stay scrollable.
        .frame(width: 620, height: 900, alignment: .topLeading)
        .background(.regularMaterial)
        .alert("存储预设", isPresented: $showingSavePreset) {
            TextField("预设名称", text: $newPresetName)
            Button("存储") {
                if model.savePreset(named: newPresetName) {
                    selectedPreset = newPresetName
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("存到 \(model.presetStore.directory.path)")
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("导出")
                .font(.system(size: 14, weight: .bold))
            Text(model.errorText ?? model.summaryLine)
                .font(.system(size: 11))
                .foregroundStyle(model.errorText == nil ? AnyShapeStyle(.secondary)
                                                        : AnyShapeStyle(Color.red))
                .fixedSize(horizontal: false, vertical: true)
            if let presetError = model.presetError {
                Text(presetError)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.red)
            }
            if let draftNotice = model.draftNotice {
                Text(draftNotice)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: 位置

    private var locationSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("目标目录").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(model.outputDirectory.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .trailing)
                Button("选择…") { model.onChooseDirectory?() }
                    .controlSize(.mini)
            }
            HStack(spacing: 8) {
                Text("子文件夹").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                TextField("{date}/{camera}", text: $model.preset.subfolder)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 220)
                    .disabled(model.phase == .running)
            }
            HStack(spacing: 8) {
                Text("重名文件").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: $model.preset.conflict) {
                    ForEach(ExportConflict.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .disabled(model.phase == .running)
            }
        } header: {
            sectionHeader("位置")
        }
    }

    // MARK: 文件命名

    private var namingSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("命名模板").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                TextField("{name} / {date} / {seq} / {rating}",
                          text: $model.preset.nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 260)
                    .disabled(model.phase == .running)
            }
            HStack(spacing: 8) {
                Text("预设").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: presetSelection) {
                    Text("—").tag("")
                    // Built-ins (网络 2048) plus the user's saved files. Selecting one copies it into
                    // the draft; editing afterwards changes only the draft, never the preset file.
                    ForEach(model.presetPickerNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
                .disabled(model.phase == .running)
                Button("存储…") {
                    newPresetName = model.preset.name ?? ""
                    showingSavePreset = true
                }
                .controlSize(.mini)
                .disabled(model.phase == .running)
                Button("删除") {
                    model.deletePreset(named: selectedPreset)
                    selectedPreset = ""
                }
                .controlSize(.mini)
                .disabled(model.phase == .running || selectedPreset.isEmpty
                          || model.isBuiltInPreset(selectedPreset))
            }
        } header: {
            sectionHeader("文件命名")
        }
    }

    // MARK: 文件设置

    private var fileSection: some View {
        Section {
            // 109 §2 — one button per *writable* format. A missing encoder means a missing button,
            // not a greyed one (AVIF on an old system).
            HStack(spacing: 8) {
                Text("格式").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: formatBinding) {
                    ForEach(model.availableFormats, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 300)
                .disabled(model.phase == .running || model.availableFormats.isEmpty)
            }
            // 109 §1 — 文件设置 follows the user's list: format, HDR switch, the HDR or SDR row,
            // quality, colour, depth.
            HStack(spacing: 8) {
                Toggle(isOn: hdrEnabledBinding) {
                    Text("HDR 输出").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.preset.format == .heic
                                         ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.phase == .running || model.preset.format != .heic)
                Spacer(minLength: 8)
                if model.preset.format != .heic {
                    Text("只有 HEIC 能带 HDR")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            .background(ExportLayoutProbeHost(kind: .hdrRow))

            if model.showsGainMapRows {
                HStack(spacing: 6) {
                    Text("增益图").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: gainMapColorBinding) {
                        ForEach(GainMapColorModel.allCases, id: \.self) { colorModel in
                            Text(colorModel.displayName).tag(colorModel)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 96)
                    .disabled(model.phase == .running)
                    Picker("", selection: gainMapVersionBinding) {
                        ForEach(GainMapVersion.allCases, id: \.self) { version in
                            Text(version.displayName).tag(version)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 104)
                    .disabled(model.phase == .running)
                    Toggle(isOn: hdrHalfSizeBinding) {
                        Text("半尺寸").font(.system(size: 10))
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(model.phase == .running)
                    .help("增益图按 1/2 边长写入（-H），SDR 基底不缩放")
                }
            } else {
                HStack(spacing: 8) {
                    Text("tone mapping").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Picker("", selection: sdrToneMappingBinding) {
                        ForEach(SDRToneMapping.allCases, id: \.self) { mapping in
                            Text(mapping.displayName).tag(mapping)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 200)
                    .disabled(model.phase == .running)
                    .help("全局：Core Image 的 global tone map；无：与旧版相同的硬截断")
                }
            }

            HStack(spacing: 8) {
                Text("质量").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Slider(value: $model.preset.quality, in: 0.1 ... 1.0)
                    .controlSize(.small)
                    .frame(width: 140)
                    .disabled(model.phase == .running || !model.preset.format.supportsQuality)
                Text(String(format: "%.2f", model.preset.quality))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(model.preset.format.supportsQuality
                                     ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                    .frame(width: 38, alignment: .trailing)
            }
            // 109 §2b — three direct buttons; P3 is the default (user's 2026-10-29 口径).
            HStack(spacing: 8) {
                Text("色彩").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: $model.preset.colorSpace) {
                    Text("sRGB").tag(OutputPrimaries.sRGB)
                    Text("P3").tag(OutputPrimaries.displayP3)
                    Text("Rec2020").tag(OutputPrimaries.rec2020)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 200)
                .disabled(model.phase == .running)
            }
            // 109 §1 / 108 — only the depths this container really stores (HEIC 8/10, JPEG 8,
            // PNG/TIFF 8/16, AVIF 8).
            HStack(spacing: 8) {
                Text("位深").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: bitDepthBinding) {
                    ForEach(model.bitDepths, id: \.self) { depth in
                        Text("\(depth) 位").tag(depth)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: model.bitDepths.count > 2 ? 200 : 130)
                .disabled(model.phase == .running)
            }
        } header: {
            sectionHeader("文件设置")
        }
    }

    // MARK: 图像尺寸

    private var sizeSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("尺寸模式").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: sizingModeBinding) {
                    // 161 §2 — UI order is 原尺寸 / 长边 / 比例. `allCases` is the stored order and
                    // must not be reordered; `displayOrder` is the one the popup reads.
                    ForEach(ExportSizingMode.displayOrder, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 220)
                .disabled(model.phase == .running)
            }
            switch model.preset.sizingMode {
            case .longEdge:
                HStack(spacing: 8) {
                    Text("长边").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    SliderNumberField(value: Double(model.preset.longEdge ?? 2400),
                                      range: 1 ... 20_000, format: "%.0f",
                                      decimals: 0, fontSize: 10, width: 60,
                                      accessibilityID: "export.size.longEdge") { typed in
                        model.preset.longEdge = max(1, Int(typed.rounded()))
                    }
                    Text("px").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            case .percent:
                HStack(spacing: 8) {
                    Text("长边百分比").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    SliderNumberField(value: Double(model.preset.percent ?? 100),
                                      range: 10 ... 100, format: "%.0f",
                                      decimals: 0, fontSize: 10, width: 60,
                                      accessibilityID: "export.size.percent") { typed in
                        model.preset.percent = min(100, max(10, Int(typed.rounded())))
                    }
                    Text("%").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            case .none:
                HStack {
                    Text("按裁切后的原始像素导出")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                }
            }
        } header: {
            sectionHeader("图像尺寸")
        }
    }

    // MARK: 输出锐化

    private var sharpenSection: some View {
        Section {
            HStack(spacing: 8) {
                Toggle(isOn: sharpenEnabledBinding) {
                    Text("输出锐化").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.phase == .running)
                Spacer(minLength: 8)
                Text("最终像素之后，只影响导出文件")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                Text("强度").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Slider(value: sharpenAmountBinding, in: 0 ... 1)
                    .controlSize(.small)
                    .frame(width: 150)
                    .disabled(model.phase == .running || model.preset.sharpen == nil)
                SliderNumberField(value: model.preset.sharpen?.amount ?? 0.6,
                                  range: 0 ... 1, format: "%.2f",
                                  decimals: 2, fontSize: 10, width: 48,
                                  accessibilityID: "export.sharpen.amount") { typed in
                    updateSharpen { $0.amount = min(1, max(0, typed)) }
                }
                .disabled(model.phase == .running || model.preset.sharpen == nil)
            }
            HStack(spacing: 8) {
                Text("半径").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Slider(value: sharpenRadiusBinding, in: 0.3 ... 3)
                    .controlSize(.small)
                    .frame(width: 150)
                    .disabled(model.phase == .running || model.preset.sharpen == nil)
                SliderNumberField(value: model.preset.sharpen?.radius ?? 0.8,
                                  range: 0.3 ... 3, format: "%.1f",
                                  decimals: 1, fontSize: 10, width: 44,
                                  accessibilityID: "export.sharpen.radius") { typed in
                    updateSharpen { $0.radius = min(3, max(0.3, typed)) }
                }
                .disabled(model.phase == .running || model.preset.sharpen == nil)
                Text("px").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        } header: {
            sectionHeader("输出锐化")
        }
    }

    // MARK: 元数据

    private var metadataSection: some View {
        Section {
            HStack(spacing: 8) {
                Text("元数据").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Picker("", selection: metadataLevelBinding) {
                    ForEach(ExportMetadataLevel.allCases, id: \.self) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .disabled(model.phase == .running)
            }
            HStack(spacing: 8) {
                Toggle(isOn: writeXMPBinding) {
                    Text("写入 XMP").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(model.phase == .running || model.preset.metadataLevel != .all)
                Spacer(minLength: 8)
                Text(model.preset.metadataLevel == .all
                     ? "完整 develop 设置"
                     : "由上面的档位决定，不能再单独开关")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        } header: {
            sectionHeader("元数据")
        }
    }

    // MARK: 导出

    private var exportSection: some View {
        Section {
            Text(model.summaryLine)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
        } header: {
            sectionHeader("导出")
        }
    }

    // MARK: results

    /// 106 §B — the remaining height between the form and the footer is the results region.
    /// The empty prompt is *not* in here any more: the scroll view holds rows only, so the prompt
    /// lives on the footer line (the two used to look crammed together because of the 170 pt cap).
    /// 161 §6 — a bounded, content-sized list. `body` only builds this when there is at least one
    /// row; the height grows with the rows (capped at 176 pt, beyond which it scrolls) and the form
    /// above gives that height back. Empty is zero height, not a 140 pt blank strip.
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
                            .font(.system(size: 10,
                                          weight: row.isFailure ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.detail)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(row.isFailure
                                             ? AnyShapeStyle(Color.red)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(28, min(176, 10 + CGFloat(model.rows.count) * 18)))
        .layoutPriority(0)
        .background(ExportLayoutProbeHost(kind: .results, rowCount: model.rows.count))
    }

    // MARK: footer

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.footerStatus)
                .font(.system(size: 10))
                .foregroundStyle(model.errorText == nil
                                 ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(model.footerStatus)
                .background(ExportLayoutProbeHost(kind: .status))
            Spacer(minLength: 8)
            // 161 §7 — one list from the model: 取消 exists only in `.running`; 关闭 exists in every
            // other phase and is never offered beside a running batch.
            ForEach(model.footerItems) { item in
                if item.kind == .export {
                    Button(item.title) { perform(item.kind) }
                        .controlSize(.small)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!item.isEnabled)
                } else {
                    Button(item.title) { perform(item.kind) }
                        .controlSize(.small)
                        .disabled(!item.isEnabled)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(ExportLayoutProbeHost(kind: .footer))
    }

    // MARK: building blocks

    private func perform(_ kind: ExportSheetModel.FooterItem.Kind) {
        switch kind {
        case .reveal: model.revealInFinder()
        case .close: model.onClose?()
        case .cancel: model.cancel()
        // The controller owns item assembly (it has the session); this is the UI door.
        case .export: model.onExportRequest?()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func color(for state: ExportRow.State) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .red
        case .rendering: return .accentColor
        case .pending, .skipped, .cancelled: return .secondary
        }
    }

    // MARK: bindings

    private var presetSelection: Binding<String> {
        Binding(get: { selectedPreset },
                set: { name in
                    selectedPreset = name
                    if !name.isEmpty { model.loadPreset(named: name) }
                })
    }

    private var bitDepthBinding: Binding<Int> {
        Binding(get: { model.preset.bitDepth },
                set: { model.selectBitDepth($0) })
    }

    private var hdrEnabledBinding: Binding<Bool> {
        Binding(get: { model.hdrEnabled }, set: { model.setHDR($0) })
    }

    private var gainMapColorBinding: Binding<GainMapColorModel> {
        Binding(get: { model.gainMapColorModel }, set: { model.setGainMapColorModel($0) })
    }

    private var gainMapVersionBinding: Binding<GainMapVersion> {
        Binding(get: { model.gainMapVersion }, set: { model.setGainMapVersion($0) })
    }

    private var hdrHalfSizeBinding: Binding<Bool> {
        Binding(get: { model.hdrHalfSize }, set: { model.hdrHalfSize = $0 })
    }

    private var sdrToneMappingBinding: Binding<SDRToneMapping> {
        Binding(get: { model.sdrToneMapping }, set: { model.setSDRToneMapping($0) })
    }

    private var formatBinding: Binding<ExportFormat> {
        Binding(get: { model.preset.format },
                set: { model.selectFormat($0) })
    }

    private var sizingModeBinding: Binding<ExportSizingMode> {
        // 161 §3 — one model entry point, not an ad-hoc `preset.sizingMode = mode` in the view: the
        // setter also clears the stale `longEdge` that made 原尺寸 render at 2048.
        Binding(get: { model.preset.sizingMode }, set: { model.selectSizingMode($0) })
    }

    private var metadataLevelBinding: Binding<ExportMetadataLevel> {
        Binding(get: { model.preset.metadataLevel },
                set: { level in
                    model.preset.metadataLevel = level
                    if level != .all { model.preset.writeXMP = false }
                })
    }

    private var writeXMPBinding: Binding<Bool> {
        Binding(get: { model.preset.metadataLevel == .all && model.preset.writeXMP },
                set: { model.preset.writeXMP = $0 })
    }

    private var sharpenEnabledBinding: Binding<Bool> {
        Binding(get: { model.preset.sharpen != nil },
                set: { on in
                    model.preset.sharpen = on
                        ? (model.preset.sharpen ?? OutputSharpening(amount: 0.6, radius: 0.8))
                        : nil
                })
    }

    private var sharpenAmountBinding: Binding<Double> {
        Binding(get: { model.preset.sharpen?.amount ?? 0.6 },
                set: { value in updateSharpen { $0.amount = min(1, max(0, value)) } })
    }

    private var sharpenRadiusBinding: Binding<Double> {
        Binding(get: { model.preset.sharpen?.radius ?? 0.8 },
                set: { value in updateSharpen { $0.radius = min(3, max(0.3, value)) } })
    }

    private func updateSharpen(_ body: (inout OutputSharpening) -> Void) {
        var sharpening = model.preset.sharpen ?? OutputSharpening(amount: 0.6, radius: 0.8)
        body(&sharpening)
        model.preset.sharpen = sharpening
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
        // `nil` lets the model use 161 §5's remembered directory (or the factory default). An
        // explicit directory still wins — that is the caller asking for this run's destination.
        let model = ExportSheetModel(outputDirectory: outputDirectory)
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 900),
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
        // 161 §5 — the close-time write. It saves the last *exported* draft when there is one (M3),
        // so unexported edits cannot overwrite what the next sheet should start from.
        model.saveDraftOnClose()
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
        var captured = session.exportItems(for: assets)
        // The catalog already knows the camera key; the subfolder token needs it on the item.
        for index in captured.indices where index < assets.count {
            captured[index].cameraKey = assets[index].cameraKey
        }
        items = captured
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
