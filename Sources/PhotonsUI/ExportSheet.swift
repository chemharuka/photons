import PhotonsLocalization
import AppKit
import PhotonsFileAccess
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
        case .noSourceFile(let name): return L10n.tr("717f9803e3f6" , String(describing: (name)))
        case .noPixels(let name): return L10n.tr("a8ae871ce8f5" , String(describing: (name)))
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
                              native: ImageSize?, deferResampling: Bool = false) throws -> DisplayImage {
        guard let url = item.sourceURL else { throw UIExportError.noSourceFile(item.name) }
        let edit = item.edit ?? .neutral
        let decoder = try RAWDecoder()
        let isRAW = UIExportSource.isRAW(url)

        let source: ImageSize
        if let native, native.width > 0, native.height > 0 {
            source = native
        } else {
            source = try UIExportSource.size(at: url)
        }

        let content = edit.geometry.outputPixels(in: source)
        let scale = preset.renderScale(content: content)
        let decodeScale = decodeScaleLadder(scale)
        // The social slicer owns the final resampling algorithm. Keep the decoded resolution
        // for that caller instead of first shrinking through the graph's regular resize stage.
        let renderScale = deferResampling ? 1 : scale / Double(decodeScale)
        // 194: the export is the **settled** picture, so it develops at the document's own balance —
        // the same development the loupe settles on — and the graph is told the buffer already carries
        // it (S1 identity below). Exporting the as-shot buffer with an S1 gain instead would ship the
        // drag's approximation as the file.
        //
        // The rest of `decodeInputs` follows the same rule: leaving out `decoderVersion` made 导出
        // always develop at Apple's default even when the user had picked v9 in 「解码模型」, and
        // leaving out `detail` shipped the untouched noise-reduction/detail amounts while the screen
        // showed the adjusted ones. The export must ask for the document's development, not a subset.
        let inputs = edit.decodeInputs
        let exportWhiteBalance = inputs.whiteBalance
        let decoded = try isRAW ? decoder.decode(url, options: DecodeOptions(decoderVersion: inputs.decoderVersion,
                                                                    scale: decodeScale,
                                                                    whiteBalance: exportWhiteBalance,
                                                                    detail: inputs.detail))
            : UIExportSource.decodeRaster(url, scale: decodeScale)

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
                                                      sourceURL: url,
                                                      whiteBalance: isRAW ? exportWhiteBalance : .asShot),
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
                                    scale: renderScale,
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
                                              scale: renderScale,
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
                                                  toneMap: preset.sdrToneMapping == .standard ? .standard:.global)
        }
        let options = RenderOptions(canvas: nil,
                                    scale: renderScale,
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
    public var detail: String = L10n.tr("251bc40e7027")
    public var fileURL: URL?
    public var pixelSize: ImageSize?
    public var seconds: Double = 0
    public var warnings: [String] = []

    public init(id: String, name: String, state: State = .pending, detail: String = L10n.tr("251bc40e7027"),
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
        case .mono: return L10n.tr("47d88357c5ea")
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
    public static let sectionTitles = [L10n.tr("1fb4d574da92"), L10n.tr("3df3f90a5922"), L10n.tr("d4ac0d4b1a6c"), L10n.tr("71a90485d565"),
                                       L10n.tr("aeae1c799c94"), L10n.tr("76420433f22d")]

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

    public func chooseOutputDirectory(_ url: URL) {
        do { try FileAccessStore.shared.rememberSelection(url); outputDirectory = url; errorText = nil }
        catch { errorText = L10n.tr("3576a63b4da7" , String(describing: (error.localizedDescription))) }
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
    public var allowsLinearDNG = false {
        didSet { if allowsLinearDNG && hdrEnabled {usesLinearDNG=hdrTabDNG} }
    }
    public var usesLinearDNG = false
    private var hdrTabPreset: ExportPreset?
    private var sdrTabPreset: ExportPreset?
    private var hdrTabDNG = false

    /// Each output mode retains its own format, sizing, colour and destination rules.
    public func selectOutputTab(hdr: Bool) {
        let currentHDR = hdrEnabled || usesLinearDNG
        guard hdr != currentHDR else { return }
        rememberOutputTab()
        if hdr {
            preset = hdrTabPreset ?? Self.defaultPreset
            usesLinearDNG = allowsLinearDNG && hdrTabDNG
        } else {
            var initial = preset
            initial.hdr = HDRExport(enabled: false)
            initial.sdrToneMapping = .standard
            preset = sdrTabPreset ?? initial
            usesLinearDNG = false
        }
        hdrPreferredKinds[preset.format] = preset.hdrKind == .none ? preset.format.defaultHDRKind : preset.hdrKind
        setHDR(hdr)
        if !hdr { preset.sdrToneMapping = .standard }
    }

    private func rememberOutputTab() {
        let hdr = hdrEnabled || usesLinearDNG
        if hdr {
            hdrTabPreset = preset
            if allowsLinearDNG {
                hdrTabDNG = usesLinearDNG
                draftStore.setExportDraftData(Data([usesLinearDNG ? 1:0]),forKey:"photons.exportTab.dng.v1")
            }
        }
        else { sdrTabPreset = preset }
        ExportDraftPersistence.save(preset: preset, outputDirectory: outputDirectory,
                                    to: draftStore, key: "photons.exportTab.\(hdr ? "hdr" : "sdr").v1")
    }
    public var selectionCount: Int = 0 {
        didSet { resetFinishedReportAfterConfigurationChange() }
    }

    /// 163 §1.6 — the selected pictures' **crop content** sizes (before the preset's scale). The
    /// controller fills this alongside `natives`; the sheet uses it to update the even-pixel warning
    /// live as the user changes size/percentage. It is not persisted.
    public var selectionContents: [ImageSize] = []

    /// 168 §2 — the selected pictures' **own** pixel sizes, straight from the catalog's
    /// `width`/`height` (never a thumbnail). The 长边 default comes from the first entry, because a
    /// batch export describes one size for all of them and the first picture is the one the user is
    /// looking at. Filled by `ExportSheetController.refreshItems`, beside `selectionContents`.
    public var selectionNatives: [ImageSize] = []

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
            notice = L10n.tr("25ae3a0ab83e")
        }

        let startingPreset = preset ?? remembered?.preset ?? Self.defaultPreset
        self.preset = startingPreset
        self.hdrPreferredEnabled = startingPreset.hdr?.enabled
            ?? startingPreset.format.hdrIsOnByDefault
        // 216 — every container starts from its own table row. A starting preset that names a kind
        // is that container's remembered choice; the others keep their defaults.
        var kinds = Dictionary(uniqueKeysWithValues: ExportFormat.allCases.map {
            ($0, $0.defaultHDRKind)
        })
        if startingPreset.hdrKind != .none { kinds[startingPreset.format] = startingPreset.hdrKind }
        self.hdrPreferredKinds = kinds
        self.outputDirectory = outputDirectory ?? remembered?.directoryURL
            ?? Self.defaultOutputDirectory
        self.writableUTIs = writableUTIs ?? ExportFormat.writableUTIs
        let store = presetStore ?? ExportPresetStore()
        self.presetStore = store
        self.presetNames = store.names
        self.draftNotice = notice
        hdrTabDNG = draftStore.exportDraftData(forKey:"photons.exportTab.dng.v1")?.first == 1
        if case .draft(let draft) = ExportDraftPersistence.recall(from: draftStore, key: "photons.exportTab.hdr.v1") { hdrTabPreset = draft.preset }
        if case .draft(let draft) = ExportDraftPersistence.recall(from: draftStore, key: "photons.exportTab.sdr.v1") { sdrTabPreset = draft.preset }
    }

    /// The factory draft (161 §1/§9): the picture's **own** size, quality 0.85, HEIC + HDR gain map +
    /// P3. The sheet is the one surface that owns this draft, so the values live here rather than in
    /// `ExportPreset()` (whose JPEG default is the CLI/API default).
    ///
    /// `nonisolated`: a default argument is evaluated at the call site, which is not the main actor,
    /// and both of these are pure values.
    public nonisolated static var defaultPreset: ExportPreset {
        ExportPreset(name: L10n.tr("844b8cc8dff7"), format: .heic, quality: 0.85,
                     bitDepth: 8, colorSpace: .displayP3, sdrToneMapping: .global,
                     hdr: HDRExport(gainMap: .iso), writeXMP: false, nameTemplate: "{name}",
                     sizingMode: ExportSizingMode.none, ppi: 240)
    }

    /// 161 §1 — the old factory draft, still selectable in the preset popup. It has its own name and
    /// purpose (a HEIC safe to hand to anyone), so it keeps its 2048 long edge and 0.95 quality; only
    /// the **default** moved.
    public nonisolated static var network2048Preset: ExportPreset {
        ExportPreset(name: L10n.tr("645306984b87"), format: .heic, longEdge: 2048, quality: 0.95,
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
            .appendingPathComponent(L10n.tr("d5ab4fc6e60d"), isDirectory: true)
    }

    // MARK: HDR (106)

    /// The user's last HDR checkbox choice. Kept here (not in a fresh `@State`) so a format round
    /// trip — HEIC → JPEG → HEIC — restores what they picked instead of resetting to `true`.
    public private(set) var hdrPreferredEnabled: Bool
    /// 216 — the user's last HDR *kind* **per container**. Every entry starts at that container's
    /// `defaultHDRKind`, and only an explicit pick (`setHDRKind`) rewrites it, so a format switch
    /// falls back to the new container's own kind without overwriting (or inheriting) another one's.
    public private(set) var hdrPreferredKinds: [ExportFormat: HDRKind]

    /// 216 — the kind the current container will use: what the user last picked there, else its
    /// default. Reading it never mutates the memory, so TIFF's automatic PQ cannot stick to HEIC.
    public var hdrPreferredKind: HDRKind {
        hdrPreferredKinds[preset.format] ?? preset.format.defaultHDRKind
    }

    /// What the checkbox shows. Every writable container has at least one HDR kind (JPEG: gain map;
    /// PNG/TIFF: PQ/HLG; HEIC/AVIF: all), so the row is only off when the user turns it off.
    public var hdrEnabled: Bool {
        guard !availableHDRKinds.isEmpty else { return false }
        return preset.hdr?.enabled ?? hdrPreferredEnabled
    }

    public var hdrGainMap: HDRExport.GainMap {
        get { preset.hdr?.gainMap ?? .iso }
        set { updateHDR { $0.gainMap = newValue } }
    }

    /// 163 §1.3 — which HDR path the sheet is offering (增益图 / HLG / PQ). 216 — the default is the
    /// current container's `defaultHDRKind` (gain map for JPEG/HEIC/AVIF, PQ for TIFF/PNG); the row
    /// only shows while HDR is on.
    public var hdrKind: HDRKind {
        get { preset.hdrKind }
        set { setHDRKind(newValue) }
    }

    /// The kinds this container may carry, in display order. JPEG offers only the gain map (no 8-bit
    /// PQ/HLG); PNG/TIFF offer only the two transfer curves; HEIC/AVIF offer all three.
    public var availableHDRKinds: [HDRKind] {
        preset.format.hdrKinds.filter { $0 != .none }
    }

    /// 163 §1.3 — choosing PQ/HLG locks the bit depth to the container's one legal value (HEIF 10,
    /// PNG/TIFF 16) in the same write, so the UI can never leave a `validated()`-illegal pair behind.
    public func setHDRKind(_ kind: HDRKind) {
        if kind == .none {
            setHDR(false)
            return
        }
        guard preset.format.supports(kind) else { return }
        hdrPreferredKinds[preset.format] = kind
        updateHDR { $0.kind = kind }
        if let locked = preset.format.hdrTransferBitDepth(for: kind) {
            preset.bitDepth = locked
        }
        if kind != .none { hdrPreferredEnabled = true }
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
    /// 163 — PQ/HLG are single-picture paths, so the gain-map row only appears for `.gainMap`.
    public var showsGainMapRows: Bool { hdrEnabled && preset.hdrKind == .gainMap }
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
    /// 163 §1.3 — while PQ/HLG is selected this is the single locked value, not a menu.
    public var bitDepths: [Int] {
        hdrEnabled ? preset.format.bitDepths(for: preset.hdrKind) : preset.format.bitDepths
    }

    public func selectBitDepth(_ depth: Int) {
        guard bitDepths.contains(depth) else { return }
        preset.bitDepth = depth
    }

    /// The 文件设置 picker's door. 216: HDR stays on across a format switch — the new container
    /// falls back to its own remembered kind (TIFF/PNG from a gain map land on PQ) instead of turning
    /// HDR off. A depth the new container cannot store is clamped, then locked by that kind.
    public func selectFormat(_ format: ExportFormat) {
        guard availableFormats.contains(format) else { return }
        preset.format = format
        preset.bitDepth = format.clampedBitDepth(preset.bitDepth)
        applyHDR(enabled: hdrPreferredEnabled)
    }

    /// The HDR checkbox. Writes through to the preset the batch will use.
    public func setHDR(_ enabled: Bool) {
        hdrPreferredEnabled = enabled
        applyHDR(enabled: enabled)
    }

    private func applyHDR(enabled: Bool) {
        guard enabled else {
            updateHDR { $0.enabled = false }
            return
        }
        // 216 — the container's remembered kind, else its table default. The fallback never writes
        // back into the memory: another container's choice must not leak into this one.
        let remembered = hdrPreferredKind
        let kind = preset.format.supports(remembered)
            ? remembered : preset.format.defaultHDRKind
        guard kind != .none else {
            updateHDR { $0.enabled = false }
            return
        }
        updateHDR { $0.kind = kind }
        if let locked = preset.format.hdrTransferBitDepth(for: kind) {
            preset.bitDepth = locked
        }
    }

    private func updateHDR(_ body: (inout HDRExport) -> Void) {
        // 216 — a preset without an HDR block (a legacy SDR draft) now starts HDR on, and its kind
        // comes from the same table the sheet and the tests read.
        var hdr = preset.hdr ?? HDRExport(enabled: preset.format.hdrIsOnByDefault,
                                          kind: preset.format.defaultHDRKind)
        body(&hdr)
        preset.hdr = hdr
    }

    // MARK: sizing (161 §1–§3)

    /// 161 §1–§3 — the 尺寸模式 popup's one write path. Setting the mode is not enough on its own: the old draft
    /// carries a `longEdge`, and `ExportPreset.renderScale` still honours it in `.none` mode. That was
    /// the "选原尺寸却出 2048" break — the popup wrote `.none`, but the renderer kept the 2048 ceiling.
    /// Clearing it here makes `原尺寸` mean scale 1 for the whole path (prediction, render, batch).
    ///
    /// 168 §2 — switching **to** 长边 starts from the current picture's own long edge (catalog pixels,
    /// not a thumbnail), not the old hard-coded 2048. An already-set value is kept: switching photos
    /// or re-entering the mode must not throw away what the user typed.
    public func selectSizingMode(_ mode: ExportSizingMode) {
        preset.sizingMode = mode
        switch mode {
        case .none:
            preset.longEdge = nil
        case .longEdge:
            if preset.longEdge == nil { preset.longEdge = currentLongEdge ?? 2048 }
        case .percent:
            if preset.percent == nil { preset.percent = 100 }
        }
    }

    /// 168 §2 — the first selected picture's long edge, in catalog pixels. `nil` when the catalog has
    /// no real dimensions for the selection (then `selectSizingMode` keeps a neutral fallback).
    ///
    /// `selectionNatives` is the primary source (the asset's own pixels). `selectionContents` is the
    /// same catalog measurement after the crop, and is the fallback for a caller that only filled
    /// that one — still real pixels, never a thumbnail.
    public var currentLongEdge: Int? {
        let sizes = selectionNatives.isEmpty ? selectionContents : selectionNatives
        guard let first = sizes.first else { return nil }
        let edge = max(first.width, first.height)
        return edge > 0 ? edge : nil
    }

    /// 206 — the PPI row's one write path: `nil` turns the tag off, a number is clamped to
    /// `ExportPreset.ppiRange` instead of being rejected (a typed 700 means "the maximum").
    public func setPPI(_ value: Int?) {
        preset.ppi = value.map {
            min(max($0, ExportPreset.ppiRange.lowerBound), ExportPreset.ppiRange.upperBound)
        }
    }

    /// 217 — the quality row's one write path, shared by its slider and its number field. A legal
    /// number is clamped into the slider's 0.10–1.00 travel and kept at the two decimals the row
    /// shows; a non-finite value never reaches `preset`.
    public func setQuality(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.10), 1.00)
        preset.quality = (clamped * 100).rounded() / 100
    }

    /// The exact struct handed to `BatchExporter`. A defensive normalisation as well as the panel
    /// write: a saved/legacy preset with `sizingMode == .none` *and* a stale `longEdge` must not
    /// render at 2048 just because it did not pass through `selectSizingMode`.
    public var effectivePreset: ExportPreset {
        var out = preset
        if out.sizingMode == .none { out.longEdge = nil }
        if !out.isHDR { out.sdrToneMapping = .standard }
        if usesLinearDNG { out.watermarkText = "" }
        return out
    }

    /// Complete selection only: a partial dimension list must never understate a batch's size.
    public var estimatedFileSize: ExportFileSizeEstimate? {
        guard selectionCount > 0, selectionContents.count == selectionCount else { return nil }
        return ExportFileSizeEstimator.estimate(contents: selectionContents, preset: effectivePreset, linearDNG: usesLinearDNG)
    }

    private var rememberedWatermarkText = "Photons"
    public var watermarkEnabled: Bool { !usesLinearDNG && !preset.watermarkText.isEmpty }
    public var canChooseWatermark: Bool { phase != .running && !usesLinearDNG }
    public var canEditWatermark: Bool { canChooseWatermark && watermarkEnabled }

    public func setWatermarkEnabled(_ enabled: Bool) {
        guard canChooseWatermark else { return }
        if enabled {
            if preset.watermarkText.isEmpty { preset.watermarkText = rememberedWatermarkText }
        } else {
            if !preset.watermarkText.isEmpty { rememberedWatermarkText = preset.watermarkText }
            preset.watermarkText = ""
        }
    }

    /// 206 — the output pixel size for one crop, through the same `ExportSizing` + gain-map trim the
    /// batch uses. `predictedSizeText` and the MP readout both read this, so the sheet cannot show a
    /// number the file will not have.
    public func predictedOutputSize(native: ImageSize) -> ImageSize {
        let preset = effectivePreset
        var size = ExportSizing.outputSize(content: native,
                                           scale: preset.renderScale(content: native))
        if preset.hdrKind == .gainMap, preset.hdr?.halfSize == true {
            size = GainMapSizing.plan(size, halfSize: true).output
        }
        return size
    }

    /// What the output pixels will be for a crop of `native`. The sheet's prediction and the batch's
    /// render both go through `ExportSizing`, so this is a forecast, not a restatement.
    /// 163 §1.6 — a half-size gain map trims an odd edge, so the forecast shows the real output.
    public func predictedSizeText(native: ImageSize) -> String {
        let size = predictedOutputSize(native: native)
        return "\(size.width)×\(size.height)"
    }

    /// 206 — the 图像尺寸 section's MP line, from the same predicted output size as
    /// `predictedSizeText` (never `width × percent` by hand). One output size prints `"24.0 MP"`
    /// (one decimal, rounded half away from zero); several different output sizes print
    /// `"N 种尺寸"` instead of pretending one number describes the batch. `nil` when the selection
    /// has no measured pixels yet, so the row is absent rather than wrong.
    public var predictedMegapixelText: String? {
        let sizes = selectionNatives.isEmpty ? selectionContents : selectionNatives
        guard !sizes.isEmpty else { return nil }
        let outputs = sizes.map { predictedOutputSize(native: $0) }
        let distinct = Set(outputs.map { "\($0.width)x\($0.height)" })
        if distinct.count > 1 { return L10n.tr("6e5204815fae" , String(describing: (distinct.count))) }
        let size = outputs[0]
        let megapixels = Double(size.width) * Double(size.height) / 1_000_000
        return String(format: "%.1f MP", (megapixels * 10).rounded() / 10)
    }

    /// 163 §1.6 — the conditional grey line under the half-size control. `nil` when the control is
    /// off, the HDR kind is not a gain map, or every selected output is already even (no blank row).
    public var halfSizeCropHint: String? {
        guard hdrEnabled, preset.hdrKind == .gainMap,
              (preset.hdr?.halfSize ?? true), !selectionContents.isEmpty else { return nil }
        var odd: [(input: ImageSize, crop: HalfSizeCrop)] = []
        for content in selectionContents {
            let size = ExportSizing.outputSize(content: content,
                                               scale: preset.renderScale(content: content))
            let plan = GainMapSizing.plan(size, halfSize: true)
            if plan.crop.isNeeded { odd.append((size, plan.crop)) }
        }
        guard let first = odd.first else { return nil }
        if odd.count == 1 {
            return first.crop.hint(current: first.input)
        }
        return L10n.tr("bdf4beaeab81" , String(describing: (odd.count)))
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
            return L10n.tr("8befa2a07247" , String(describing: (selectionCount)), String(describing: (preset.summary)))
        case .running:
            return String(format: L10n.tr("e6cef430ff9d"), rendered, total, elapsed)
        case .finished:
            var parts = [String(format: L10n.tr("96085eea637f"), writtenCount)]
            if skippedCount > 0 { parts.append(L10n.tr("4d18c2642395" , String(describing: (skippedCount)))) }
            if cancelledCount > 0 { parts.append(L10n.tr("b02ce763959f" , String(describing: (cancelledCount)))) }
            if failedCount > 0 { parts.append(L10n.tr("3a34291a5331" , String(describing: (failedCount)))) }
            return parts.joined(separator: "，") + String(format: L10n.tr("8b1e627269ec"), elapsed)
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
            return [FooterItem(kind: .cancel, title: L10n.tr("2cd0f3be8738"), isEnabled: true),
                    FooterItem(kind: .export, title: L10n.tr("76420433f22d"), isEnabled: false)]
        }
        var items: [FooterItem] = []
        if phase == .finished {
            if writtenCount > 0 {
                items.append(FooterItem(kind: .reveal, title: L10n.tr("1280364b7f84"), isEnabled: true))
            }
            // §7's finished order: 在 Finder 中显示 → 再导出一次 → 关闭.
            items.append(FooterItem(kind: .export, title: L10n.tr("2636b822b377"), isEnabled: canRun))
            items.append(FooterItem(kind: .close, title: L10n.tr("3fd47edce45b"), isEnabled: true))
        } else {
            items.append(FooterItem(kind: .close, title: L10n.tr("3fd47edce45b"), isEnabled: true))
            items.append(FooterItem(kind: .export, title: L10n.tr("76420433f22d"), isEnabled: canRun))
        }
        return items
    }

    /// The footer's one line: the empty prompt, live progress, or the finished report. Errors win —
    /// they are why a run stopped, and the footer is where the user is looking after pressing 导出.
    public var footerStatus: String {
        if let errorText { return errorText }
        if phase == .idle, rows.isEmpty { return L10n.tr("78f5de17aa24") }
        return summaryLine
    }

    // MARK: running

    /// Validate, then hand the batch to the engine on a worker. Returns immediately.
    ///
    /// - Parameter natives: asset id → the asset's own pixel size, when the catalog knows it. Items
    ///   without an entry are probed. This is what keeps the UI out of the decoder for sizes.
    public func run(items: [ExportItem], natives: [String: ImageSize] = [:],
                    renderer: ((ExportItem, ExportPreset, CancellationToken) throws -> DisplayImage)? = nil) {
        guard phase != .running else { return }
        guard !items.isEmpty else {
            errorText = L10n.tr("e555a1dcbb2b")
            return
        }
        do {
            _ = try preset.validated()
        } catch {
            errorText = error.localizedDescription
            return
        }
        let directoryAccess = FileAccessStore.shared.access(to: outputDirectory)
        if preset.destination == .chosenFolder && SandboxEnvironment.isSandboxed && !FileManager.default.isWritableFile(atPath: directoryAccess.url.path) {
            errorText = L10n.tr("c18d1bb2234b")
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
        let directory = directoryAccess.url
        let sourceAccess = items.flatMap { [$0.sourceURL, $0.originalDirectory ?? $0.sourceURL?.deletingLastPathComponent()].compactMap { $0 } }.map { FileAccessStore.shared.access(to: $0) }
        // 161 §5 — what a successful run remembers. The draft is the *run's* snapshot, so a field
        // the user changes after the report appears cannot leak into "last used".
        pendingRunDraft = ExportDraftPersistence.Draft(preset: preset, outputDirectory: directory)
        let render: (ExportItem, ExportPreset) throws -> DisplayImage = { item, preset in
            let image = try renderer?(item, preset, token)
                ?? UIExportRenderer.render(item: item, preset: preset, native: natives[item.id])
            // Called on a `BatchExporter` worker: the counter belongs to the main actor.
            DispatchQueue.main.async { [weak self] in self?.markRendered(item.id) }
            return image
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { withExtendedLifetime((directoryAccess, sourceAccess)) {} }
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
            rows[index].detail = L10n.tr("52c96167103d")
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
                    row.detail += L10n.tr("ed497cfb86f2" , String(describing: (outcome.warnings.count)))
                }
            } else if outcome.cancelled {
                row.state = .cancelled
                row.detail = L10n.tr("a37778f17c5f")
            } else if outcome.skipped {
                row.state = .skipped
                row.detail = L10n.tr("4b283e22c613")
            } else {
                row.state = .failed
                row.detail = L10n.tr("7880bd8e5238" , String(describing: (outcome.error ?? L10n.tr("a1a9da9ee6ed"))))
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
        rememberOutputTab()
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
            replayHDRPreference()
            presetError = nil
            return
        } catch {
            // A built-in has no file; fall back to it by name before surfacing the file error.
            if let builtIn = Self.builtInPresets.first(where: { $0.name == name }) {
                preset = builtIn
                replayHDRPreference()
                presetError = nil
                return
            }
            presetError = error.localizedDescription
        }
    }

    /// 216 — a loaded preset is a choice for **its** container: remember its kind there, take its
    /// on/off switch, and replay that switch for every format (it used to be HEIC only). An explicit
    /// `enabled: false` therefore survives the load; so does an explicit PQ on a TIFF preset.
    private func replayHDRPreference() {
        hdrPreferredEnabled = preset.hdr?.enabled ?? preset.format.hdrIsOnByDefault
        hdrPreferredKinds[preset.format] = preset.hdrKind == .none
            ? preset.format.defaultHDRKind : preset.hdrKind
        applyHDR(enabled: hdrPreferredEnabled)
    }

    @discardableResult
    public func savePreset(named name: String) -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presetError = L10n.tr("1e396cf6fce0")
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

/// 302 —— 折叠状态。键 `photons.export.section.<title>`，默认**收起**：
/// 一屏是 6 个常驻决定 + 3 个折叠标题 = 9 个 band（`ExportSheetLayout301Tests` 的
/// `testTheFirstScreenShowsAtMostTenRows` 量的就是这 9 个；322 之前是 7 + 3 = 10）。
///
/// 注入式（`read` / `write` 两个闭包）是为了让 hosted 测试能拿一份内存实现把三段都展开、
/// 读回完整的 20 行栅格，而不去动真实的 `UserDefaults`。
public struct ExportSectionCollapseStore {
    public var read: (String) -> Bool?
    public var write: (String, Bool) -> Void

    public init(read: @escaping (String) -> Bool?, write: @escaping (String, Bool) -> Void) {
        self.read = read
        self.write = write
    }

    static func key(_ title: String) -> String { "photons.export.section.\(title)" }

    public static let userDefaults = ExportSectionCollapseStore(
        read: { UserDefaults.standard.object(forKey: ExportSectionCollapseStore.key($0)) as? Bool },
        write: { title, expanded in
            UserDefaults.standard.set(expanded, forKey: ExportSectionCollapseStore.key(title))
        })

    static func memory(_ seed: [String: Bool] = [:]) -> ExportSectionCollapseStore {
        final class Box { var values: [String: Bool] = [:] }
        let box = Box()
        box.values = seed
        return ExportSectionCollapseStore(read: { box.values[$0] },
                                          write: { title, expanded in
                                              box.values[title] = expanded
                                          })
    }
}

/// The sheet's contents. A leaf: every control writes `model.preset` (the exact struct the batch
/// will use) and nothing else, so what the sheet shows is what the files get.
///
/// 302 —— 结构回到「表单」：单列 560，7 个常驻决定 + 3 个折叠段，底部一条摘要/按钮带。
public struct ExportSheetView: View {
    @Bindable public var model: ExportSheetModel

    @State private var selectedPreset = ""
    @State private var showingSavePreset = false
    @State private var newPresetName = ""
    @State private var expandedSections: Set<String>

    private let sectionStore: ExportSectionCollapseStore

    static let colourSection = L10n.tr("c70580d20561")
    static let hdrSection = L10n.tr("47b3920963c5")
    static let afterSection = L10n.tr("72abcd917c88")

    public init(model: ExportSheetModel,
                sectionStore: ExportSectionCollapseStore = .userDefaults) {
        self.model = model
        self.sectionStore = sectionStore
        let titles = [Self.colourSection, Self.hdrSection, Self.afterSection]
        _expandedSections = State(initialValue: Set(titles.filter { sectionStore.read($0) == true }))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Picker(L10n.tr("1e5b3b2d1762"), selection: Binding(get:{model.hdrEnabled || model.usesLinearDNG},set:{ value in
                model.selectOutputTab(hdr:value)
            })) { Text("HDR").tag(true);Text("SDR").tag(false) }
                .pickerStyle(.segmented).padding(.bottom,14).disabled(model.phase == .running)
            form
            if !model.rows.isEmpty {
                results
            }
            footer
        }
        // 388 —— 左右不等：左边 20，右边 20 + scrollerGutter(16)。面板加宽 16，内容右沿仍是 540。
        // overlay 式滚动指示条画在内容之上、不占布局宽度，所以这 16 pt 只能是**面板**多出来的宽度，
        // 不能靠缩窄内容腾出来（那样读数与百分数会左移，与 335 的 540 锚点冲突）。
        .padding(.leading, ExportRowGrid.horizontalPadding)
        .padding(.trailing, ExportRowGrid.trailingPadding)
        .padding(.vertical, ExportRowGrid.horizontalPadding)
        // 576 —— sheet 固定宽（`ExportSheetController.present` 也按这个宽度开窗），不再随窗口。
        .frame(width: ExportRowGrid.panelWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .onAppear {if !model.hdrEnabled {model.preset.sdrToneMapping = .standard}}
        .alert(L10n.tr("99ae75bfd658"), isPresented: $showingSavePreset) {
            TextField(L10n.tr("5fe110aa6d1d"), text: $newPresetName)
                .font(.system(size: ExportRowGrid.Font.control))
            Button(L10n.tr("a3434acddb75")) {
                if model.savePreset(named: newPresetName) {
                    selectedPreset = newPresetName
                }
            }
            Button(L10n.tr("2cd0f3be8738"), role: .cancel) {}
        } message: {
            Text(L10n.tr("77da66648c1b" , String(describing: (model.presetStore.directory.path))))
        }
    }

    // MARK: header

    /// 面板标题 13 semibold（唯一的大字号）+ 预设（顶栏，和标题同一条带）+ 一行摘要。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Text(L10n.tr("76420433f22d"))
                    .font(.system(size: ExportRowGrid.Font.title, weight: .semibold))
                Spacer(minLength: 8)
                presetControls
            }
            if let errorText = model.errorText {
                Text(errorText)
                    .font(.system(size: ExportRowGrid.Font.control))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let presetError = model.presetError {
                Text(presetError)
                    .font(.system(size: ExportRowGrid.Font.hint))
                    .foregroundStyle(Color.red)
            }
            if let draftNotice = model.draftNotice {
                Text(draftNotice)
                    .font(.system(size: ExportRowGrid.Font.hint))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.bottom, 12)
    }

    private var presetControls: some View {
        HStack(spacing: 6) {
            Picker("", selection: presetSelection) {
                Text(L10n.tr("5d4140e4c5e3")).tag("")
                ForEach(model.presetPickerNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .exportControlFont("export.preset", kind: .picker)
            .frame(width: ExportRowGrid.presetWidth, alignment: .trailing)
            .disabled(model.phase == .running)
            Button(L10n.tr("99ae75bfd658")) {
                newPresetName = model.preset.name ?? ""
                showingSavePreset = true
            }
            .controlSize(.small)
            .disabled(model.phase == .running)
            Button(L10n.tr("2f9daa828907")) {
                model.deletePreset(named: selectedPreset)
                selectedPreset = ""
            }
            .controlSize(.small)
            .disabled(model.phase == .running || selectedPreset.isEmpty
                      || model.isBuiltInPreset(selectedPreset))
        }
    }

    // MARK: form

    private var form: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                // 6 个常驻行是同一个节奏：pitch 32（24 高 + 8 缝）。
                VStack(alignment: .leading, spacing: ExportRowGrid.rowSpacing) {
                    residentRows
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !model.usesLinearDNG {
                    colourSectionView
                    if model.hdrEnabled {hdrSectionView}
                }
                afterSectionView
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // 388 —— 与下面 ScrollView 的负 padding 成对：ScrollView 向右破出多少，内容就缩进多少。
            .padding(.trailing, ExportRowGrid.scrollerBleed)
        }
        // 161 §6 —— 滚动区吃掉剩余高度；没有结果行时底部不留空白条。
        .frame(maxHeight: .infinity)
        .scrollIndicators(.visible)
        // 388 —— 把 ScrollView 本身伸到面板右缘：overlay 式指示条贴的是 ScrollView 的右缘，
        // 不是面板的。只加内容 padding 是没用的（实测 523…540 压着百分数）。
        .padding(.trailing, -ExportRowGrid.scrollerBleed)
        .background(ExportLayoutProbeHost(kind: .form))
    }

    /// 6 个常驻决定，顺序固定。HDR 关时多一行 SDR 色调映射（它是 HDR 关时的核心决定，
    /// 不能藏进折叠段，否则 168 的「色调映射行跟着 HDR 走」就无法在视图里成立）。
    ///
    /// 322 —— 322 之前这里是 7 行：水印不透明度曾经常驻，现在它是水印段里的第三行。
    @ViewBuilder
    private var residentRows: some View {
        formatRow
        if model.usesLinearDNG {
            Text(L10n.tr("27d6867d773e")).font(.caption).foregroundStyle(.secondary)
        }
        if model.showsToneMappingRow && !model.usesLinearDNG {
            toneMappingRow
        }
        // 302 —— 质量：容器没有质量档时这一行仍在（滑杆/数值禁用）。**为什么不对 PNG / TIFF 直接
        // 抽掉**：250 的真实点击测试靠行位置稳定（先点 PPI 再换格式），少一行会让探针 frame 过期。
        // 收窄发生在选项层：位深、HDR 类型都按容器给（不出现没有的选项）。
        exportSliderRow(label: L10n.tr("55847d2e5bed"), value: model.preset.quality * 100,
                        range: 10 ... 100, format: "%.0f", decimals: 0,
                        unit: "%", enabled: model.phase != .running
                            && model.preset.format.supportsQuality && !model.usesLinearDNG,
                        axID: "export.quality") { typed in
            model.setQuality(typed / 100)
        }
        sizeRow
        if !model.usesLinearDNG {
        exportSliderRow(label: "PPI", value: Double(model.preset.effectivePPI ?? 240),
                        range: 72 ... 600, format: "%.0f", decimals: 0,
                        unit: L10n.tr("0d2fed4d4197"), enabled: model.phase != .running,
                        axID: "export.ppi", showsSlider: false,
                        labelToggle: ExportRowToggle(title: "PPI", isOn: ppiEnabledBinding,
                                                     axID: "export.ppi.enabled"),
                        placeholder: model.preset.ppi == nil ? L10n.tr("640ecddb555a") : nil,
                        readoutPlacement: .inline) { typed in
            model.setPPI(Int(typed.rounded()))
        }
        }
        // 322 —— 水印不透明度不再是常驻行：它是水印的三件事之一（文字 → 位置 → 不透明度），
        // 现在整个在水印折叠段里。常驻行因此 7 → 6。
        directoryRow
        namingRow
    }

    /// 109 §2 —— 只列有编码器的格式（缺编码器 = 缺一项，不是灰一项）。HDR 开关是格式行的修饰，
    /// 贴在控件块右沿（`.hdrRow` 的探针也挂在这条 24 pt 的行上，格式切换不会让行高变）。
    private var formatRow: some View {
        ExportRowGridRow(
            rowID: "export.format",
            label: { rowLabel(L10n.tr("0e8b1c78c5f3")) },
            control: {
                Picker("", selection: Binding(get:{model.usesLinearDNG ? "dng":model.preset.format.rawValue},set:{ value in
                    model.usesLinearDNG = value == "dng"
                    if value == "dng" {model.setHDR(true)}
                    else if let format=ExportFormat(rawValue:value) {formatBinding.wrappedValue=format}
                })) {
                    if model.allowsLinearDNG && model.hdrEnabled {Text(L10n.tr("edc6e86229fa")).tag("dng")}
                    ForEach(model.availableFormats.filter { !model.hdrEnabled || !$0.hdrKinds.isEmpty }, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .exportControlFont("export.format", kind: .picker)
                .frame(maxWidth: ExportRowGrid.menuWidth, alignment: .leading)
                .disabled(model.phase == .running || model.availableFormats.isEmpty)
            },
            value: { EmptyView() },
            unit: { EmptyView() },
            accessory: {
                EmptyView()
            })
            .background(ExportLayoutProbeHost(kind: .hdrRow))
    }

    /// 109 §3 / 168 §1 —— 只有 SDR 才有这一行；HDR 关时它就是首屏的核心决定。
    private var toneMappingRow: some View {
        ExportRowGridRow(
            rowID: "export.hdr.toneMapping",
            label: { rowLabel(L10n.tr("8c38852df3df")) },
            control: {
                Text(SDRToneMapping.standard.displayName)
                    .font(.system(size:11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal:false,vertical:true)

            },
            value: { EmptyView() },
            unit: { EmptyView() },
            accessory: { EmptyView() })
            .background(ExportToneMappingRowProbeHost())
    }

    /// 302 草图里的 `尺寸 [长边 ▾] [4096] px`：模式、数值、单位在**同一行**，
    /// 数值走唯一的 `SliderNumberField`，所以三种尺寸模式的数值框都落在同一根 x 上。
    @ViewBuilder
    private var sizeRow: some View {
        switch model.preset.sizingMode {
        case .longEdge:
            exportSliderRow(label: L10n.tr("246df7d8db84"), value: Double(model.preset.longEdge ?? 2400),
                            range: 1 ... 20_000, format: "%.0f", decimals: 0,
                            unit: "px", enabled: model.phase != .running,
                            axID: "export.size.longEdge", showsSlider: false,
                            picker: AnyView(sizeModePicker),
                            trailingToggle: ExportRowToggle(
                                title: L10n.tr("8f3e3c390021"), isOn: $model.preset.noUpscale,
                                axID: "export.size.noUpscale",
                                help: L10n.tr("2f6aaa2691c2"))) { typed in
                model.preset.longEdge = max(1, Int(typed.rounded()))
            }
        case .percent:
            exportSliderRow(label: L10n.tr("246df7d8db84"), value: Double(model.preset.percent ?? 100),
                            range: 10 ... 100, format: "%.0f", decimals: 0,
                            unit: "%", enabled: model.phase != .running,
                            axID: "export.size.percent", showsSlider: false,
                            picker: AnyView(sizeModePicker)) { typed in
                model.preset.percent = min(100, max(10, Int(typed.rounded())))
            }
        case .none:
            exportSliderRow(label: L10n.tr("246df7d8db84"), value: 0, range: 0 ... 1, format: "%.0f", decimals: 0,
                            enabled: false, axID: "export.size.original", showsSlider: false,
                            picker: AnyView(sizeModePicker), placeholder: L10n.tr("fc7b0426c7b1")) { _ in }
        }
    }

    /// 尺寸模式 + 预测像素量：同一行里，模式是控件，像素量是它右边的次级读数。
    private var sizeModePicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: sizingModeBinding) {
                // 161 §2 —— UI 顺序是 原尺寸 / 长边 / 比例；`allCases` 是存储顺序，不能改。
                ForEach(ExportSizingMode.displayOrder, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .exportControlFont("export.size.mode", kind: .picker)
            .frame(maxWidth: ExportRowGrid.presetWidth)
            .disabled(model.phase == .running)
            if let megapixels = model.predictedMegapixelText {
                Text(megapixels)
                    .font(.system(size: ExportRowGrid.Font.hint, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    // 322 —— 它排在模式选择后面，`HStack` 先压它：模式选择拿 150 之后只剩 41 pt，
                    // 像素量一长（「11.2 MP」量出来 47.6）就成「11.2 M…」。它不参与压缩：
                    // 拿自己的理想宽，剩下的给模式选择与空白。
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("export.size.megapixels")
                    // 322 —— 它是「尺寸」行的次级读数：自己的探针，量的是布局真分给它的宽度。
                    .background(ExportRowGridProbeHost(kind: .accessory,
                                                       rowID: "export.size.megapixels"))
            }
            Spacer(minLength: 0)
        }
    }

    private var directoryRow: some View {
        ExportRowGridRow(
            rowID: "export.location.directory",
            label: { rowLabel(L10n.tr("531bccd8f330")) },
            control: {
                // 335 —— 按钮回到主列**左端**（138 起），文案去掉省略号（「更改…」→「更改」：
                // 它开的是同一个目录面板，省略号在这里只占了 15 pt 的宽度）。路径拿剩下的宽度。
                HStack(spacing: ExportRowGrid.readoutGap) {
                    Picker(L10n.tr("f6727cfa6281"), selection: $model.preset.destination) {
                        ForEach(ExportDestination.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }.labelsHidden().frame(width:150)
                    Button(L10n.tr("6b01fce4dbea")) { model.onChooseDirectory?() }

                        .controlSize(.small)
                        .background(ExportRowGridProbeHost(kind: .button,
                                                           rowID: "export.location.directory.change"))
                    Text(model.preset.destination == .sourceFolder ? L10n.tr("eed4ef2c6677") : model.outputDirectory.path)
                        .font(.system(size: ExportRowGrid.Font.hint, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(model.outputDirectory.path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(ExportRowGridProbeHost(kind: .accessory,
                                                           rowID: "export.location.directory.path"))
                }
            },
            value: { EmptyView() },
            unit: { EmptyView() },
            accessory: { EmptyView() })
    }

    private var namingRow: some View {
        ExportRowGridRow(
            rowID: "export.naming.template",
            label: { rowLabel(L10n.tr("41aa3ae4ba1c")) },
            control: {
                TextField(L10n.tr("3c86dcbd3eee"), text: $model.preset.nameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .exportControlFont("export.naming.template", kind: .textField,
                                       design: .monospaced)
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase == .running)
            },
            value: { EmptyView() },
            unit: { EmptyView() },
            accessory: { EmptyView() })
    }

    // MARK: 颜色与元数据

    private var colourSectionView: some View {
        ExportCollapsibleSection(Self.colourSection, summary: L10n.tr("dded3a8a45bd"),
                                 isExpanded: isExpanded(Self.colourSection),
                                 toggle: { toggleSection(Self.colourSection) }) {
            ExportRowGridRow(
                rowID: "export.colorSpace",
                label: { rowLabel(L10n.tr("3c663ac9fe3f")) },
                control: {
                    Picker("", selection: $model.preset.colorSpace) {
                        Text("sRGB").tag(OutputPrimaries.sRGB)
                        Text("P3").tag(OutputPrimaries.displayP3)
                        Text("Rec2020").tag(OutputPrimaries.rec2020)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .exportControlFont("export.colorSpace", kind: .picker)
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.bitDepth",
                label: { rowLabel(L10n.tr("09220325fb3e")) },
                control: {
                    Picker("", selection: bitDepthBinding) {
                        ForEach(model.bitDepths, id: \.self) { depth in
                            Text(L10n.tr("60dcc1d0f458" , String(describing: (depth)))).tag(depth)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .exportControlFont("export.bitDepth", kind: .picker)
                    .frame(maxWidth: .infinity)
                    .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.metadata.level",
                label: { rowLabel(L10n.tr("aeae1c799c94")) },
                control: {
                    Picker("", selection: metadataLevelBinding) {
                        ForEach(ExportMetadataLevel.allCases, id: \.self) { level in
                            Text(level.displayName).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .exportControlFont("export.metadata.level", kind: .picker)
                    .frame(maxWidth: ExportRowGrid.menuWidth, alignment: .leading)
                    .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.metadata.xmp",
                label: {
                    // 335 —— 勾选标签也走墨迹对齐（`checkboxLabel` 内部把文字推到墨迹右沿 130）。
                    checkboxLabel(L10n.tr("c5f7efdab1bc"), isOn: writeXMPBinding,
                                  enabled: model.phase != .running
                                      && model.preset.metadataLevel == .all,
                                  axID: "export.metadata.xmp")
                },
                control: {
                    // 322 —— 说明允许两行：放不下就换行，不许省成「…」。
                    Text(model.preset.metadataLevel == .all
                         ? L10n.tr("31b79bd08181")
                         : L10n.tr("80444de1efc5"))
                        .font(.system(size: ExportRowGrid.Font.hint))
                        .foregroundStyle(.tertiary)
                        // 322 —— 宽度先钉在控件列上，`Text` 才知道该换行（不钉它按 ideal 排成
                        // 一行，然后被 frame 硬切，连「…」都没有）。
                        .frame(maxWidth: ExportRowGrid.controlWidth, alignment: .leading)
                        .lineLimit(2)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.metadata.location",
                label: {
                    checkboxLabel(L10n.tr("8d367c10c398"), isOn: $model.preset.removeLocation,
                                  enabled: model.phase != .running
                                      && model.preset.metadataPolicy != .none,
                                  axID: "export.metadata.location")
                },
                control: {
                    Text(L10n.tr("9549136d6cdc"))
                        .font(.system(size: ExportRowGrid.Font.hint))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: ExportRowGrid.controlWidth, alignment: .leading)
                        .lineLimit(2)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
        }
    }

    // MARK: HDR 与色调映射

    private var hdrSectionView: some View {
        ExportCollapsibleSection(Self.hdrSection, summary: L10n.tr("3b779e4f8396"),
                                 isExpanded: isExpanded(Self.hdrSection),
                                 toggle: { toggleSection(Self.hdrSection) }) {
            if model.availableHDRKinds.isEmpty {
                ExportRowGridRow(
                    rowID: "export.hdr.unavailable",
                    label: { EmptyView() },
                    control: {
                        Text(L10n.tr("0d80f9331307"))
                            .font(.system(size: ExportRowGrid.Font.hint))
                            .foregroundStyle(.tertiary)
                    },
                    value: { EmptyView() },
                    unit: { EmptyView() },
                    accessory: { EmptyView() })
            } else {
                ExportRowGridRow(
                    rowID: "export.hdr.kind",
                    label: { rowLabel(L10n.tr("c39de769f2a9")) },
                    control: {
                        Picker("", selection: hdrKindBinding) {
                            ForEach(model.availableHDRKinds, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .exportControlFont("export.hdr", kind: .picker)
                        .frame(maxWidth: .infinity)
                        .disabled(model.phase == .running || !model.hdrEnabled)
                    },
                    value: { EmptyView() },
                    unit: { EmptyView() },
                    accessory: { EmptyView() })
                if model.showsGainMapRows {
                    ExportRowGridRow(
                        rowID: "export.hdr.gainMap",
                        label: { rowLabel(L10n.tr("a26f95b6e25d")) },
                        control: {
                            HStack(spacing: 6) {
                                Picker("", selection: gainMapColorBinding) {
                                    ForEach(GainMapColorModel.allCases, id: \.self) { colorModel in
                                        Text(colorModel.displayName).tag(colorModel)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .exportControlFont("export.hdr.gainMap", kind: .picker)
                                .frame(width: 110)
                                .disabled(model.phase == .running)
                                Picker("", selection: gainMapVersionBinding) {
                                    ForEach(GainMapVersion.allCases, id: \.self) { version in
                                        Text(version.displayName).tag(version)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                                .exportControlFont("export.hdr.gainMap.version", kind: .picker)
                                .frame(maxWidth: .infinity)
                                .disabled(model.phase == .running)
                            }
                        },
                        value: { EmptyView() },
                        unit: { EmptyView() },
                        accessory: { EmptyView() })
                    ExportRowGridRow(
                        rowID: "export.hdr.halfSize",
                        label: {
                            checkboxLabel(L10n.tr("d92531be7845"), isOn: hdrHalfSizeBinding,
                                          enabled: model.phase != .running,
                                          axID: "export.hdr.halfSize",
                                          help: L10n.tr("5a0598078455"))
                        },
                        control: {
                            // 322 —— 裁偶数边的说明有 377.9 pt（「半尺寸需要偶数像素：当前
                            // 4096×2731，将裁到 …」），一行装不下：两行，行高按内容长。
                            if let hint = model.halfSizeCropHint {
                                Text(hint)
                                    .font(.system(size: ExportRowGrid.Font.hint))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: ExportRowGrid.controlWidth, alignment: .leading)
                                    .lineLimit(2)
                                    .help(hint)
                            } else {
                                Text(L10n.tr("1b01ecd28138"))
                                    .font(.system(size: ExportRowGrid.Font.hint))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: ExportRowGrid.controlWidth, alignment: .leading)
                                    .lineLimit(2)
                            }
                        },
                        value: { EmptyView() },
                        unit: { EmptyView() },
                        accessory: { EmptyView() })
                }
            }
        }
    }

    // MARK: 输出后

    private var afterSectionView: some View {
        ExportCollapsibleSection(Self.afterSection, summary: L10n.tr("78fa88728927"),
                                 isExpanded: isExpanded(Self.afterSection),
                                 toggle: { toggleSection(Self.afterSection) }) {
            ExportRowGridRow(
                rowID: "export.location.subfolder",
                label: { rowLabel(L10n.tr("e23ca17e6026")) },
                control: {
                    TextField("{date}/{camera}", text: $model.preset.subfolder)
                        .textFieldStyle(.roundedBorder)
                        .exportControlFont("export.location.subfolder", kind: .textField,
                                           design: .monospaced)
                        .frame(maxWidth: .infinity)
                        .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.location.conflict",
                label: { rowLabel(L10n.tr("c2d4b5ca3438")) },
                control: {
                    Picker("", selection: $model.preset.conflict) {
                        ForEach(ExportConflict.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .exportControlFont("export.location.conflict", kind: .picker)
                    .frame(maxWidth: ExportRowGrid.menuWidth, alignment: .leading)
                    .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.watermark.text",
                label: { rowLabel(L10n.tr("454aca5e7137")) },
                control: {
                    HStack {
                        Picker(L10n.tr("aa9f217c8186"), selection: Binding(get: { model.watermarkEnabled }, set: model.setWatermarkEnabled)) {
                            Text(L10n.tr("484d55613910")).tag(false)
                            Text(L10n.tr("14b69bd6eeb0")).tag(true).disabled(model.usesLinearDNG)
                        }
                        .pickerStyle(.menu).labelsHidden().frame(width: 90)
                        .disabled(!model.canChooseWatermark)
                        .accessibilityIdentifier("export.watermark.mode")
                        .help(model.usesLinearDNG ? L10n.tr("export.watermark.dngHint") : L10n.tr("aa9f217c8186"))
                        TextField(L10n.tr("454aca5e7137"), text: Binding(
                            get: { model.usesLinearDNG ? "" : model.preset.watermarkText },
                            set: { model.preset.watermarkText = $0 }))
                            .disabled(model.phase == .running || model.usesLinearDNG)
                    }
                        .textFieldStyle(.roundedBorder)
                        .exportControlFont("export.watermark.text", kind: .textField)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("export.watermark.text")
                        .disabled(model.phase == .running)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            ExportRowGridRow(
                rowID: "export.watermark.position",
                label: { rowLabel(L10n.tr("3ed692b960f2")) },
                control: {
                    Picker("", selection: $model.preset.watermarkPosition) {
                        ForEach(WatermarkPosition.allCases, id: \.self) { position in
                            Text(position.displayName).tag(position)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .exportControlFont("export.watermark.position", kind: .picker)
                    .frame(maxWidth: ExportRowGrid.menuWidth, alignment: .leading)
                    .accessibilityIdentifier("export.watermark.position")
                    .disabled(!model.canEditWatermark)
                },
                value: { EmptyView() },
                unit: { EmptyView() },
                accessory: { EmptyView() })
            // 322 —— 水印的三件事在一段里，顺序：文字 → 位置 → 不透明度。
            exportSliderRow(label: L10n.tr("a53d909714ae"), value: model.preset.watermarkOpacity,
                            range: 0 ... 100, format: "%.0f", decimals: 0,
                            unit: "%", enabled: model.canEditWatermark,
                            axID: "export.watermark.opacity") { typed in
                // 288 —— 滑杆连续，5 % 的量化在写入路径上。
                let quantized = (typed / 5).rounded() * 5
                model.preset.watermarkOpacity = min(100, max(0, quantized))
            }
            if model.usesLinearDNG {
                Text(L10n.tr("export.watermark.dngHint"))
                    .font(.system(size: ExportRowGrid.Font.hint))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("export.watermark.disabledHint")
            }
        }
    }

    // MARK: 折叠

    private func isExpanded(_ title: String) -> Bool { expandedSections.contains(title) }

    private func toggleSection(_ title: String) {
        if expandedSections.contains(title) {
            expandedSections.remove(title)
        } else {
            expandedSections.insert(title)
        }
        sectionStore.write(title, expandedSections.contains(title))
    }

    // MARK: results

    /// 106 §B / 161 §6 —— 有行才建；高度随行数长，超过 176 pt 自己滚，上面的 form 让出等高。
    private var results: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.rows) { row in
                    HStack(spacing: 6) {
                        Image(systemName: row.state.symbol)
                            .font(.system(size: 10))
                            .foregroundStyle(color(for: row.state))
                            .frame(width: 12)
                        Text(row.name)
                            .font(.system(size: ExportRowGrid.Font.control,
                                          weight: row.isFailure ? .semibold : .regular))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(row.detail)
                            .font(.system(size: ExportRowGrid.Font.hint, design: .monospaced))
                            .foregroundStyle(row.isFailure
                                             ? AnyShapeStyle(Color.red)
                                             : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.warnings.isEmpty ? row.detail
                                                       : row.warnings.joined(separator: "\n"))
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
            // 388 —— 与 form 同一招：结果列表的 overlay 指示条也不许压住 `detail` 文字。
            .padding(.trailing, ExportRowGrid.scrollerBleed)
        }
        .frame(maxWidth: .infinity)
        .frame(height: max(28, min(176, 10 + CGFloat(model.rows.count) * 18)))
        .layoutPriority(0)
        .padding(.trailing, -ExportRowGrid.scrollerBleed)
        .background(ExportLayoutProbeHost(kind: .results, rowCount: model.rows.count))
    }

    // MARK: footer

    /// 302 §2A —— 摘要行 22 / 按钮 28，**同一条水平带**（中心差 ≤ 1 pt），左右都是 20 pt padding。
    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                ExportFileSizeLabel(estimate: model.estimatedFileSize)
                if model.phase != .idle || model.errorText != nil {
                    Text(model.footerStatus)
                        .font(.system(size: ExportRowGrid.Font.footer))
                        .foregroundStyle(model.errorText == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.red))
                        .lineLimit(1).truncationMode(.middle).help(model.footerStatus)
                }
            }
            .frame(minHeight: ExportRowGrid.footerHeight, alignment: .leading)
            .background(ExportRowGridProbeHost(kind: .summary, rowID: "export.footer.summary"))
            .background(ExportLayoutProbeHost(kind: .status))
            Spacer(minLength: 8)
            HStack(alignment: .center, spacing: 8) {
                ForEach(model.footerItems) { item in
                    footerButton(item)
                }
            }
            .frame(height: ExportRowGrid.buttonHeight)
            .background(ExportRowGridProbeHost(kind: .buttons, rowID: "export.footer.buttons"))
        }
        // 323b — 页脚按钮（`controlSize(.large)` 的系统高度略高于 `buttonHeight`）曾贴到上面那条
        // 分隔线上：内容与分隔线只差 10 pt，圆角与阴影压住了 1 px 的线。按钮尺寸不动，改成
        // 内容上下各留出余量（`minHeight` 而非固定高度，避免被裁），页脚因此长高 12 pt。
        .frame(minHeight: ExportRowGrid.buttonHeight)
        .padding(.vertical, 6)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(.separator)
                .frame(height: 1)
        }
        .background(ExportLayoutProbeHost(kind: .footer))
        .padding(.top, 12)
    }

    @ViewBuilder
    private func footerButton(_ item: ExportSheetModel.FooterItem) -> some View {
        if item.kind == .export {
            Button(item.title) { perform(item.kind) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!item.isEnabled)
        } else {
            Button(item.title) { perform(item.kind) }
                .controlSize(.large)
                .disabled(!item.isEnabled)
        }
    }

    // MARK: building blocks

    private func perform(_ kind: ExportSheetModel.FooterItem.Kind) {
        switch kind {
        case .reveal: model.revealInFinder()
        case .close: model.onClose?()
        case .cancel: model.cancel()
        // The controller owns item assembly (it is the one with the session); this is the UI door.
        case .export: model.onExportRequest?()
        }
    }

    /// 335 —— 标签对齐的是**墨迹**右沿（130），不是文本框右沿。
    ///
    /// 「PPI」里 `I` 的墨迹右边不贴 advance box 右边，把文本框对到 130 之后 `I` 右边还差一条缝，
    /// 用户看到的就是「PPI 没右对齐」。`labelInkShift` 量出这条 bearing（汉字几乎为 0），
    /// 再把文本框往右挪同样多 —— 负的 trailing padding 让超出列右沿的那几 pt 落到 8 pt 的列间距里。
    private func rowLabel(_ text: String) -> some View {
        labelText(text, inkProbeID: text)
            .padding(.trailing, -ExportRowGrid.labelInkShift(for: text))
    }

    /// 标签文字（标签列与勾选框共用）。`inkProbeID` 非空时挂一条 `.labelInk` 探针 ——
    /// 它记的是**文本框**的 frame，墨迹右沿 = frame 右沿 − `labelInkInset(text)`。
    /// 行修饰（「不扩大」）不挂探针：它不在标签列上。
    private func labelText(_ text: String, inkProbeID: String?) -> some View {
        Group {
            if let inkProbeID {
                baseLabelText(text)
                    .background(ExportRowGridProbeHost(kind: .labelInk, rowID: inkProbeID,
                                                       text: text))
            } else {
                baseLabelText(text)
            }
        }
    }

    private func baseLabelText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: ExportRowGrid.Font.label, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// 335 —— 标签列里的勾选框（「写入 XMP」「移除位置」「半尺寸」）：文字墨迹右沿 130。
    ///
    /// 勾选框没有点击框包装，`Toggle` 自己的右沿就是文字的 advance box 右沿，所以只需要 bearing
    /// 那一项修正 —— 和纯文字标签同一条规则。
    private func checkboxLabel(_ title: String, isOn: Binding<Bool>, enabled: Bool,
                              axID: String, help: String? = nil) -> some View {
        Toggle(isOn: isOn) {
            labelText(title, inkProbeID: axID)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .disabled(!enabled)
        .help(help ?? title)
        .padding(.trailing, -ExportRowGrid.labelInkShift(for: title, checkbox: true))
    }

    /// 勾选框：探测框就是**盒子那一端**（点击测试在 `minX + 7`），所以它从标签列右沿往左贴 ——
    /// 勾选框是行修饰，位置固定，不跟标签文字的长短跑。
    ///
    /// 322 —— 框宽按**自己的文字**量（`ExportRowGrid.toggleBoxWidth`）。302 把它写死成 34，
    /// 「不扩大」「写入 XMP」「移除位置」「半尺寸」「PPI」全部比 34 宽，于是界面上是「不扩…」。
    ///
    /// 335 —— 墨迹修正：勾选框的点击框右边有 `toggleTrailingSlack`（4）的余量，文字墨迹还要再让
    /// 开自己的 bearing。两段合起来 `labelInkShift(checkbox: true)` 往右推，墨迹才落在 130 上。
    /// 点击框因此伸到 134 左右 —— 仍在 8 pt 的列间距里，碰不到 138 的控件。
    ///
    /// `isLabel == false` 是行修饰（「不扩大」贴在控件块右沿），它不属于标签列，不做墨迹修正。
    private func rowToggle(_ toggle: ExportRowToggle, enabled: Bool,
                           isLabel: Bool = true) -> some View {
        Color.clear
            .frame(width: ExportRowGrid.toggleBoxWidth(for: toggle.title),
                   height: ExportRowGrid.rowHeight)
            .overlay(alignment: .leading) {
                // 335 —— 勾选框在它的点击框里**右对齐**：这样文字的右沿就是点击框的右沿（可控、
                // 可量），墨迹修正只剩 bearing 一项。322 的 4 pt 余量仍在框里（点击手感不变），
                // 只是把文字推到框的右边。
                Toggle(isOn: toggle.isOn) {
                    labelText(toggle.title, inkProbeID: isLabel ? toggle.axID : nil)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .disabled(!enabled)
                .accessibilityIdentifier(toggle.axID)
                .help(toggle.help ?? toggle.title)
                .frame(width: ExportRowGrid.toggleBoxWidth(for: toggle.title),
                       alignment: .trailing)
            }
            .background(ExportSliderRowProbeHost(kind: .toggle, rowID: toggle.axID))
            .padding(.trailing, isLabel
                     ? -ExportRowGrid.labelInkShift(for: toggle.title, checkbox: true) : 0)
    }

    private func color(for state: ExportRow.State) -> Color {
        switch state {
        case .done: return .green
        case .failed: return .red
        case .rendering: return .accentColor
        case .pending, .skipped, .cancelled: return .secondary
        }
    }

    // MARK: numeric rows

    /// 243 — 属于数值行的勾选框：`label` 形是行标签（PPI），`trailing` 形是行修饰（不扩大）。
    private struct ExportRowToggle {
        var title: String
        var isOn: Binding<Bool>
        var axID: String
        var help: String? = nil
    }

    /// 288 / 302 —— 数值行唯一的读数：46 宽的 `SliderNumberField`，右对齐在读数块里。
    /// 整个文件只有 `numberReadout` 这一处构造它（243 的结构守卫读的就是这个）。
    @ViewBuilder
    private func numberReadout(axID: String, value: Double, range: ClosedRange<Double>,
                               format: String, decimals: Int,
                               enabled: Bool, placeholder: String?,
                               write: @escaping (Double) -> Void) -> some View {
        if let placeholder {
            Text(placeholder)
                .font(.system(size: ExportRowGrid.Font.hint))
                .foregroundStyle(.tertiary)
                .background(ExportSliderRowProbeHost(kind: .number, rowID: axID))
        } else {
            SliderNumberField(value: value, range: range, format: format,
                              decimals: decimals,
                              fontSize: ExportRowGrid.Font.value,
                              width: ExportRowGrid.valueWidth,
                              accessibilityID: axID, onCommit: write)
                .disabled(!enabled)
                .background(ExportSliderRowProbeHost(kind: .number, rowID: axID))
        }
    }

    /// 288 —— 每个数值行都走面板的同一套栅格。滑杆连续（不传 `step:`，SwiftUI 就不画刻度）；
    /// 质量 / 水印不透明度 / 长边百分比在写入路径上量化。
    ///
    /// 335 —— 滑杆不再贴「控件块右沿 424」：它从主列起点 138 起、吃掉读数留下的宽度，右沿落在
    /// 百分数左边 8 pt 处。读数（值 46 + 单位）贴主列右沿 540；PPI 行是唯一例外（`.inline`）：
    /// 输入框在 138、单位「像素/英寸」紧随其后，两者都在主列左端。
    private func exportSliderRow(
        label: String, value: Double, range: ClosedRange<Double>,
        format: String, decimals: Int, unit: String? = nil,
        enabled: Bool, axID: String,
        showsSlider: Bool = true,
        picker: AnyView? = nil,
        labelToggle: ExportRowToggle? = nil,
        trailingToggle: ExportRowToggle? = nil,
        placeholder: String? = nil,
        readoutPlacement: ExportReadoutPlacement = .trailing,
        write: @escaping (Double) -> Void
    ) -> some View {
        ExportRowGridRow(
            rowID: axID,
            readout: readoutPlacement,
            label: {
                if let labelToggle {
                    rowToggle(labelToggle, enabled: enabled)
                } else {
                    rowLabel(label)
                }
            },
            control: {
                if let picker {
                    picker
                } else if showsSlider {
                    AdjustmentSlider(value: Binding(get: { value }, set: write), in: range)
                        .controlSize(.small)
                        .frame(minWidth: ExportRowGrid.sliderWidth, maxWidth: .infinity)
                        .background(ExportSliderRowProbeHost(kind: .slider, rowID: axID))
                        .disabled(!enabled)
                } else {
                    // 335 —— 没有滑杆也没有下拉（PPI）：控件位是零宽，读数从主列起点 138 起排。
                    EmptyView()
                }
            },
            value: {
                numberReadout(axID: axID, value: value, range: range, format: format,
                              decimals: decimals, enabled: enabled,
                              placeholder: placeholder, write: write)
            },
            unit: {
                if let unit {
                    Text(unit)
                        .font(.system(size: ExportRowGrid.Font.unit))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .background(ExportSliderRowProbeHost(kind: .unit, rowID: axID))
                } else {
                    EmptyView()
                }
            },
            accessory: {
                if let trailingToggle {
                    rowToggle(trailingToggle, enabled: enabled, isLabel: false)
                } else {
                    EmptyView()
                }
            })
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

    private var ppiEnabledBinding: Binding<Bool> {
        Binding(get: { model.preset.ppi != nil },
                set: { on in model.setPPI(on ? (model.preset.ppi ?? 240) : nil) })
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

    private var hdrKindBinding: Binding<HDRKind> {
        Binding(get: { model.hdrKind }, set: { model.setHDRKind($0) })
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
        // 161 §3 —— 唯一入口，不是视图里手写 `preset.sizingMode = mode`：setter 还会清掉那条
        // 让「原尺寸」渲染在 2048 的旧 longEdge。
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
    private var sizeProbeGeneration = UUID()
    private let sizeProbeQueue = DispatchQueue(label: "Photons.exportDimensions", qos: .userInitiated)

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
        model.selectOutputTab(hdr:ProcessingPreferences.hdrPreview)
        refreshItems()
        model.selectionCount = items.count
        if let existing = sheetWindow, existing.sheetParent != nil {
            return
        }
        // 302 —— 面板固定 560 宽（内容自适应上限 640），不再用 620×900 的列表画布。
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: ExportRowGrid.panelWidth,
                                                  height: ExportRowGrid.contentMaxHeight),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.title = L10n.tr("ab95f2111084" , String(describing: (model.selectionCount)))
        // 321 —— 面板尺寸是**应用**的决定，不是 SwiftUI 的 ideal 尺寸。
        //
        // 这里以前只给了 contentRect，紧跟着的 `window.contentViewController = hosting` 让 AppKit
        // 把窗口收到 hosting 的 `preferredContentSize` 上。赋值那一刻 SwiftUI 还没布局，滚动区
        // （`form`）的 ideal 高度是 0，于是窗口只剩标题 + 页脚那么高（560×110），`form` 分到 0 pt，
        // 7 个常驻行全被裁在可视区外 —— 用户看到的就是「只有模板下拉，没有具体选项」。
        // 所以两步：hosting 不再驱动窗口尺寸，然后按 560×640 把窗口撑回来，滚动区才有高度可分。
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: ExportRowGrid.panelWidth,
                                     height: ExportRowGrid.contentMaxHeight))
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
        // 163 §1.6 — the half-size warning needs each selected picture's cropped content size, not
        // the sensor size (a rotated crop is a different rectangle). The preset's scale is applied
        // later by `halfSizeCropHint`, so this stays valid as the user changes size.
        model.selectionContents = items.compactMap { item in
            guard let native = sizes[item.id] else { return nil }
            return (item.edit ?? .neutral).geometry.outputPixels(in: native)
        }
        // 168 §2 — the 长边 default wants the catalog's real pixels (not the cropped content, and
        // never a thumbnail), in selection order so "第一张" is the same picture the sheet names.
        model.selectionNatives = items.compactMap { sizes[$0.id] }
        model.selectionCount = items.count
        sizeProbeGeneration = UUID()
        let generation = sizeProbeGeneration
        let capturedItems = items
        let missing = capturedItems.filter { sizes[$0.id] == nil && $0.sourceURL != nil }
        guard !missing.isEmpty else { return }
        sizeProbeQueue.async { [weak self] in
            var found: [String: ImageSize] = [:]
            for item in missing {
                guard let url = item.sourceURL else { continue }
                let access = FileAccessStore.shared.access(to: url)
                found[item.id] = try? UIExportSource.size(at: access.url)
                withExtendedLifetime(access) {}
            }
            let resolved = found
            DispatchQueue.main.async {
                guard let self, self.sizeProbeGeneration == generation else { return }
                self.natives.merge(resolved) { _, new in new }
                self.model.selectionNatives = capturedItems.compactMap { self.natives[$0.id] }
                self.model.selectionContents = capturedItems.compactMap { item in
                    self.natives[item.id].map { (item.edit ?? .neutral).geometry.outputPixels(in: $0) }
                }
            }
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.tr("c11330b85234")
        panel.message = L10n.tr("006f61c8e4cc")
        panel.directoryURL = model.preset.destination == .sourceFolder
            ? items.first?.sourceURL?.deletingLastPathComponent() : model.outputDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseOutputDirectory(url)
    }
}
