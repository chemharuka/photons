import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 530 — 「编辑数值有时要等照片加载完再加载」.
///
/// The numbers a slider shows come from `CatalogSession.edit`, which `loadEditForAnchor()` assigns
/// when the selection changes. This suite pins the two promises the ticket makes:
///
///   1. a selection puts the stored document in `session.edit` **in the same runloop turn** — the
///      values do not wait for a frame;
///   2. five rapid switches never leave the previous photo's document under the new anchor.
///
/// The baseline measurement (see `local/REPORT.md`) was: `develop(forAsset:)` ~1 ms, while
/// `editHistory(forAsset:)` cost 15 ms p50 / 80 ms p95 because it decodes every snapshot. The
/// measured fix is therefore the history read on a background queue; the document itself is still
/// assigned synchronously. `testReverseGate…` holds the old "wait for the frame" order as a red
/// reference.
///
/// `testRealLibraryTenSwitches…` is the measurement (skipped unless `PHOTONS_530_LIBRARY` names a
/// real `.photonslibrary`); the other tests use a synthetic fixture so they run everywhere.
@MainActor
final class EditValuesFast530Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-edit-values-530-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - ① the promise: same turn, stored document, this asset

    func testSelectionAssignsTheStoredDocumentInTheSameTurn() throws {
        let fixture = try makeFixture()
        let session = try open(fixture)
        // `open()` lands on the first row; the switch under test is to the second photo.
        session.selectOnly(fixture.ids[1])

        XCTAssertEqual(session.loadedEditAssetID, fixture.ids[1],
                       "the anchor's id is published with the document, in this turn")
        XCTAssertEqual(session.edit.light.exposure, fixture.documents[1].light.exposure,
                       "the stored document is already `edit` when selectOnly returns")
        XCTAssertEqual(session.lastEditLoadTimeline?.assetID, fixture.ids[1])
        XCTAssertNotNil(session.lastEditLoadTimeline?.assignedAt)
    }

    // MARK: - ② values do not wait for the frame (the decode is deliberately absent)

    func testValuesAreReadableBeforeAnyFrameArrives() throws {
        let fixture = try makeFixture()
        let session = try open(fixture)
        // The slow-history seam is the fixture's "decode takes N ms": nothing below pumps events.
        session.editHistoryLoadDelayForTesting = 0.25
        session.selectOnly(fixture.ids[2])

        XCTAssertNil(session.ingestedSourceFrame,
                     "no frame has been published for this photo — the frame path is not involved")
        XCTAssertEqual(session.loadedEditAssetID, fixture.ids[2])

        let exposure = fixture.documents[2].light.exposure
        XCTAssertEqual(session.edit.light.exposure, exposure)
        XCTAssertEqual(InspectorView.sliderText("%.2f EV", session.edit.light.exposure),
                       InspectorView.sliderText("%.2f EV", exposure),
                       "the number the inspector reads is the stored one")
        XCTAssertEqual(InspectorView.lightRows.count, 7,
                       "the rows are the same table with no frame present")
        XCTAssertNil(session.lastEditLoadTimeline?.firstFrameAt)
    }

    // MARK: - ③ reverse gate: the pre-530 order (read after the frame) must be red

    /// If `loadEditForAnchor` ever goes back to assigning only after the first frame, ① fails for
    /// exactly this reason: under the new anchor the inspector would still read the previous
    /// photo's numbers. The door is test-only and off in production.
    func testReverseGateDeferringTheDocumentUntilTheFirstFrameLeavesThePreviousValues() throws {
        let fixture = try makeFixture()
        let session = try open(fixture)
        session.selectOnly(fixture.ids[0])
        session.defersDocumentUntilFirstFrameForTesting = true

        session.selectOnly(fixture.ids[1])
        XCTAssertEqual(session.loadedEditAssetID, fixture.ids[0],
                       "pre-530 order: the document is still the previous photo's")
        XCTAssertEqual(session.edit.light.exposure, fixture.documents[0].light.exposure,
                       "…and so are the numbers — this is the red the gate guards")

        // The frame is what the old order waited for. Once it lands the document follows.
        session.ingestedSourceFrame = (fixture.ids[1], ImageSize(width: 6000, height: 4000))
        XCTAssertEqual(session.loadedEditAssetID, fixture.ids[1])
        XCTAssertEqual(session.edit.light.exposure, fixture.documents[1].light.exposure)
    }

    // MARK: - ④ five rapid switches, one assertion per switch, no stale document

    func testFiveRapidSwitchesNeverLeaveThePreviousDocumentUnderTheNewAnchor() throws {
        let fixture = try makeFixture(count: 5)
        let session = try open(fixture)
        for (index, id) in fixture.ids.enumerated() {
            session.selectOnly(id)
            XCTAssertEqual(session.anchorID, id)
            XCTAssertEqual(session.loadedEditAssetID, id,
                           "switch \(index): the loaded document belongs to the current anchor")
            XCTAssertEqual(session.edit.light.exposure, fixture.documents[index].light.exposure,
                           "switch \(index): no flash-back to the previous photo's numbers")
        }
    }

    // MARK: - history still arrives, and a write waits for it

    func testTheStoredHistoryReplacesTheBaselineAndSurvivesAQuickWrite() throws {
        let fixture = try makeFixture(historyRows: 40)
        let session = try open(fixture)
        session.selectOnly(fixture.ids[1])

        // The background read lands shortly after the turn; the stored stack must replace the
        // one-row baseline.
        XCTAssertTrue(waitFor(2, {
            (session.lastEditLoadTimeline?.historyEndedAt ?? 0) > 0
        }), "the background history read never landed")
        XCTAssertEqual(session.history.count, 40,
                       "the persisted stack is the one on screen, not the floor")

        // A write immediately after a switch pulls the pending read forward instead of committing
        // onto a one-row baseline (which would truncate `asset_history`). The drag itself does not
        // wait — only the commit does.
        session.editHistoryLoadDelayForTesting = 0.2
        session.selectOnly(fixture.ids[2])
        session.applyEdit { $0.light.exposure += 0.5 }
        XCTAssertEqual(session.history.count, 1,
                       "the drag does not wait for the background history read (one-row floor)")
        session.commitEdit(label: "quick", coalesce: false)
        XCTAssertEqual(session.history.count, 41,
                       "the commit saw the stored stack before appending its snapshot")
    }

    // MARK: - the real-library measurement

    /// 10 switches from a copy of a real library, including its largest (60 MP) photo. Prints the
    /// five numbers the ticket asks for; the report carries the p50/p95. Skipped without
    /// `PHOTONS_530_LIBRARY`.
    func testRealLibraryTenSwitchesReportsTheTimeline() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_530_LIBRARY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real library; set PHOTONS_530_LIBRARY")
        }
        _ = NSApplication.shared
        let copy = workDir.appendingPathComponent("Real.photonslibrary", isDirectory: true)
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)

        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        let window = try XCTUnwrap(editor.window)
        windows.append(window)
        try editor.openLibrary(at: copy)
        let session = editor.session
        // One run for each side of the change, on the same machine (report compares them).
        let baseline = ProcessInfo.processInfo.environment["PHOTONS_530_BASELINE"] == "1"
        session.loadsEditHistorySynchronouslyForTesting = baseline
        let loupe = editor.rootView.loupeController
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        window.contentView?.layoutSubtreeIfNeeded()
        try XCTUnwrap(session.assets.count >= 10)

        // Largest first, so the 60 MP photo is certainly in the ten.
        let ids = session.assets
            .sorted { ($0.width ?? 0) * ($0.height ?? 0) > ($1.width ?? 0) * ($1.height ?? 0) }
            .prefix(10)
            .map(\.id)
        var samples: [CatalogSession.EditLoadTimeline] = []
        for id in ids {
            session.selectOnly(id)
            if let timeline = session.lastEditLoadTimeline, timeline.assetID == id {
                samples.append(timeline)
            }
            // Let the history read land; the selection path itself does not wait for it.
            _ = waitFor(10, { (session.lastEditLoadTimeline?.historyEndedAt ?? 0) > 0 })

            loupe.scheduleRender()
            guard waitFor(120, { session.lastFirstFrameAssetID == id }) else {
                return XCTFail("no first frame for \(id) (last error: \(loupe.lastPresentError ?? "—"))")
            }
            if let timeline = session.lastEditLoadTimeline, timeline.assetID == id,
               samples.last?.assetID == id {
                samples[samples.count - 1] = timeline
            }
        }

        XCTAssertEqual(samples.count, 10, "every switch produced a timeline")
        func percentile(_ values: [Double], _ p: Double) -> Double {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return 0 }
            let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
            return sorted[index]
        }
        let assigned = samples.map(\.selectionToAssignedMilliseconds)
        let develop = samples.map(\.developMilliseconds)
        let toFrame = samples.compactMap(\.assignedToFirstFrameMilliseconds)
        let history = samples.map(\.historyMilliseconds)
        print(String(format: "530 real library [%@]: select→edit p50 %.2f ms p95 %.2f ms | edit→first frame p50 %.2f p95 %.2f | develop p50 %.2f p95 %.2f | history p50 %.2f p95 %.2f",
                     baseline ? "baseline" : "fix",
                     percentile(assigned, 0.5), percentile(assigned, 0.95),
                     percentile(toFrame, 0.5), percentile(toFrame, 0.95),
                     percentile(develop, 0.5), percentile(develop, 0.95),
                     percentile(history, 0.5), percentile(history, 0.95)))
    }

    // MARK: - fixture

    private struct Fixture {
        let package: URL
        let ids: [String]
        let documents: [EditModel]
    }

    /// A library whose rows carry distinct documents and a non-trivial history, so the measured
    /// cost is the same code path a real library takes (a row's `develop_json` + `asset_history`).
    private func makeFixture(count: Int = 3, historyRows: Int = 30) throws -> Fixture {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Values.photonslibrary")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        var documents: [EditModel] = []
        for index in 0 ..< count {
            let id = UUID().uuidString
            ids.append(id)
            let name = "values\(index).dng"
            try Data([0x00]).write(to: source.appendingPathComponent(name))
            var document = EditModel.neutral
            document.light.exposure = 0.5 + Double(index)
            documents.append(document)

            let live = try Catalog.encode(document)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, develop_json, develop_version, history_end, missing)
                    VALUES (?, ?, ?, ?, 'dng', 'raw', 1, 0, ?, 6000, 4000,
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-23T00:00:00Z', ?, 1, ?, 0)
                    """, arguments: [id, root.id, name, name, UUID().uuidString, live, historyRows])
                for seq in 1 ... historyRows {
                    // Earlier states differ from the live document, as a real edit stack does.
                    var earlier = document
                    earlier.light.exposure = document.light.exposure - Double(historyRows - seq) * 0.01
                    let json = try Catalog.encode(earlier)
                    try db.execute(sql: """
                        INSERT INTO asset_history (asset_id, seq, develop_json, label, created_at)
                        VALUES (?, ?, ?, ?, '2026-11-23T00:00:00Z')
                        """, arguments: [id, seq, json, seq == historyRows ? "" : "edit \(seq)"])
                }
            }
        }
        return Fixture(package: package, ids: ids, documents: documents)
    }

    private func open(_ fixture: Fixture) throws -> CatalogSession {
        let session = CatalogSession(remembersRecentLibrary: false)
        try session.open(fixture.package)
        return session
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }
}
