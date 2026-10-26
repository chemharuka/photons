import AppKit
import PhotonsCatalog

/// 文件 ▸ 导入照片… — panel, then a *background* import, then reload + select.
///
/// The engine is synchronous (`ImportService.run` walks, hashes, writes), so it runs on its own
/// serial queue and only two things come back to the main actor: a progress tick per file, and the
/// summary. The main thread therefore never blocks on a 200-file SHA-256 pass, and the window keeps
/// drawing thumbnails while the import runs.
///
/// Cancellation is cooperative at file granularity: the flag is polled between files, the session is
/// booked `cancelled`, and everything already imported stays (the next run adopts it by content
/// hash — the same idempotency a re-run after `finished` has).
@MainActor
public final class ImportCoordinator {

    public private(set) var isImporting = false
    /// The last tick, or nil when nothing is running.
    public private(set) var progress: ImportProgress?
    public private(set) var lastSummary: ImportSummary?
    /// The thrown error, when the import could not even start (a source folder vanished).
    public private(set) var lastError: String?
    /// Imports actually started — a test asserts "one run" without inspecting threads.
    public private(set) var runCount = 0
    /// How many times the panel was put up. Every import asks (the box only *remembers*), which is
    /// what this counter exists to prove.
    public private(set) var panelPresentationCount = 0

    public var onProgress: ((ImportProgress) -> Void)?
    public var onFinish: ((ImportSummary) -> Void)?
    public var onError: ((String) -> Void)?

    /// How the panel is shown. Production is `runModal()`; a test replaces it so the interaction can
    /// be driven headlessly (creating an `NSOpenPanel` is fine — showing one is not).
    public var presentPanel: ((NSOpenPanel) -> NSApplication.ModalResponse)?

    private let session: CatalogSession
    private let defaults: UserDefaults
    private let cancelFlag = ImportCancelFlag()

    public init(session: CatalogSession, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    // MARK: panel → import

    /// 导入照片… in full: folders only, multi-select, 包含子文件夹 pre-ticked from the last run.
    ///
    /// Called on every invocation — there is no "don't ask again": the panel is the one place the
    /// decision lives, and the memory only sets its initial state.
    public func presentAndStart() {
        guard session.isOpen, !isImporting else { return }

        panelPresentationCount += 1
        let request = ImportPanel.present(ImportPanelConfiguration.load(from: defaults),
                                          defaults: defaults,
                                          present: presentPanel)
        // Writes the memory on 导入 (when a folder was picked), nothing on 取消.
        guard let request else { return }
        start(request)
    }

    // MARK: the run

    public func start(_ request: ImportRequest, completion: ((ImportSummary) -> Void)? = nil) {
        guard !isImporting else { return }
        guard let service = session.makeImportService() else {
            lastError = "未打开库"
            return
        }
        isImporting = true
        runCount += 1
        lastError = nil
        progress = ImportProgress(processed: 0, total: 0)
        cancelFlag.reset()

        let flag = cancelFlag
        service.shouldCancel = { flag.isCancelled }
        let options = request.options
        let sources = request.sources

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var summary = ImportSummary()
            var thrown: Error?
            do {
                summary = try service.run(sources: sources,
                                          options: options,
                                          onFile: { processed, total in
                                              // Per-file tick: `progress` above only fires every 100.
                                              DispatchQueue.main.async {
                                                  self?.reportProgress(processed: processed, total: total)
                                              }
                                          })
            } catch {
                thrown = error
            }
            DispatchQueue.main.async {
                self?.finish(summary, error: thrown, completion: completion)
            }
        }
    }

    /// Stop after the file that is currently in flight. A no-op when nothing is running — a second
    /// click must not look like it did something.
    public func cancel() {
        guard isImporting else { return }
        cancelFlag.cancel()
    }

    // MARK: back on the main actor

    private func reportProgress(processed: Int, total: Int) {
        guard isImporting else { return }        // a tick in flight after finish() is dropped
        let next = ImportProgress(processed: processed, total: total)
        guard next != progress else { return }
        progress = next
        onProgress?(next)
    }

    private func finish(_ summary: ImportSummary, error: Error?, completion: ((ImportSummary) -> Void)?) {
        isImporting = false
        progress = nil
        lastSummary = summary
        lastError = error.map { "\($0)" }

        // Reload first, then select: `selectImported` does both, and an empty `addedAssetIDs`
        // (duplicates only, or cancelled before the first file) leaves the selection untouched.
        session.selectImported(summary.addedAssetIDs)

        if let message = lastError { onError?(message) }
        completion?(summary)
        onFinish?(summary)
    }
}
