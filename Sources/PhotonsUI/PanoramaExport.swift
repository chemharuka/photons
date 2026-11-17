import PhotonsLocalization
import AppKit
import PhotonsFileAccess
import SwiftUI
import CoreImage
import PhotonsCore
import PhotonsExport
import PhotonsPanorama
import PhotonsJobs

enum PanoramaExportKind: Hashable { case standard, losslessDNG }

/// Adapt the frozen, scene-linear composite to the application's existing export contract.
/// The SDR base and the HDR companion always come from the same pixels.
enum PanoramaExportRenderer {
    static func render(plan: PanoramaPlan, preset: ExportPreset, cancel: CancellationToken) throws -> DisplayImage {
        let engine = PanoramaEngine()
        let cancellation = PanoramaCancellation(isCancelled: { cancel.isCancelled })
        let scene = try engine.renderComposite(plan, cancellation: cancellation)
        try cancellation.check()
        return try render(scene: scene, preset: preset)
    }

    static func render(scene: CIImage, preset: ExportPreset) throws -> DisplayImage {
        try PanoramaPixelRenderer.render(scene:scene,preset:preset)
    }
}

/// Only the pixel provider differs from a catalog export; all controls, remembered presets,
/// format/depth validation, gain maps, naming and reporting belong to ExportSheetModel.
@MainActor
final class PanoramaExportController {
    let model = ExportSheetModel()
    private var window: NSWindow?
    private let plan: PanoramaPlan
    private let manifest: PanoramaManifest
    var onQueued: (() -> Void)?
    var onExported: (URL,@escaping(String?)->Void)->Void = {_,done in done(nil)}

    init(plan: PanoramaPlan, manifest: PanoramaManifest? = nil) {
        self.plan = plan
        self.manifest = manifest ?? PanoramaManifest(plan:plan)
        model.allowsLinearDNG = true
        model.preset.nameTemplate = "{name}"
        let size = ImageSize(width: Int(plan.outputSize.width), height: Int(plan.outputSize.height))
        model.selectionCount = 1
        model.selectionNatives = [size]; model.selectionContents = [size]
        model.onClose = { [weak self] in self?.dismiss() }
        model.onChooseDirectory = { [weak self] in self?.chooseDirectory() }
        model.onReveal = { NSWorkspace.shared.activateFileViewerSelecting($0) }
        model.onExportRequest = { [weak self] in self?.run() }
    }

    func present(in parent: NSWindow) {
        model.selectOutputTab(hdr:ProcessingPreferences.hdrPreview)
        let hosting = NSHostingController(rootView: ExportSheetView(model: model))
        hosting.sizingOptions = []
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: ExportRowGrid.panelWidth,
            height: ExportRowGrid.contentMaxHeight), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = L10n.tr("229063af0cdc")
        sheet.contentViewController = hosting
        sheet.setContentSize(NSSize(width: ExportRowGrid.panelWidth, height: ExportRowGrid.contentMaxHeight))
        sheet.isReleasedWhenClosed = false
        window = sheet
        parent.beginSheet(sheet)
    }

    func dismiss() {
        model.cancel()
        model.saveDraftOnClose()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        window?.orderOut(nil); window = nil
    }

    private func chooseDirectory() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.preset.destination == .sourceFolder
            ? plan.sources.first?.url.deletingLastPathComponent() : model.outputDirectory
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.model.chooseOutputDirectory(url)
            }
        }
    }

    private func run() {
        do {
            _ = try model.preset.validated()
            let source=plan.sources.map(\.url).sorted {$0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending}.first
            let root=model.preset.destination == .sourceFolder ? (source?.deletingLastPathComponent() ?? model.outputDirectory):model.outputDirectory
            let access=FileAccessStore.shared.access(to:root)
            guard FileManager.default.isWritableFile(atPath:access.url.path) else {
                throw PanoramaFailure(L10n.tr("e8183b25e9ba"))
            }
            try BackgroundTasks.shared.submit(plan:plan,manifest:manifest,preset:model.effectivePreset,
                dng:model.usesLinearDNG,directory:model.outputDirectory,completion:onExported)
            dismiss()
            onQueued?()
        } catch {
            let alert=NSAlert();alert.messageText=error.localizedDescription
            if let window {alert.beginSheetModal(for:window)}
        }
    }
}
