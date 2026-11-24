import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 549 (= 550) — 导出结束后后台栏保留末张缩略图；行内方块按中心裁成 1:1。
///
/// Reverse gates (kept as comments, verified by hand):
///   · putting `store.clearCurrent(id:)` back into `ExportSheetModel.finish` makes ① red;
///   · dropping `centerSquare` and using `.scaleProportionallyUpOrDown` makes ③ red (the row's
///     bitmap keeps the source's 600×400 aspect instead of a 400×400 centre crop).
@MainActor
final class ExportRowThumb549Tests: XCTestCase {

    private var workDir: URL!
    private var draftStore: MemoryDraftStore!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-row549-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        draftStore = MemoryDraftStore()
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private func model(store: BackgroundTaskStore) -> ExportSheetModel {
        let model = ExportSheetModel(presetStore: ExportPresetStore(directory: workDir),
                                     draftStore: draftStore,
                                     backgroundTasks: store)
        model.outputDirectory = workDir
        model.imageRenderer = { _, _, _ in Self.displayImage() }
        return model
    }

    private static func displayImage() -> DisplayImage {
        DisplayImage(width: 4, height: 4,
                     rgba: [Float16](repeating: 0.5, count: 4 * 4 * 4),
                     primaries: .displayP3, bitDepth: 8)
    }

    private func assets(_ names: [String]) -> [Asset] {
        names.map { name in
            Asset(id: name, sourceRootId: "root-549", relPath: "\(name).dng",
                  filename: "\(name).dng", ext: "dng", kind: .raw, size: 1, mtime: 0,
                  contentHash: "hash-\(name)", width: 600, height: 400)
        }
    }

    private func exportItems(_ assets: [Asset]) -> [ExportItem] {
        assets.map { ExportItem(id: $0.id, name: $0.filename) }
    }

    private func thumbKeys(_ assets: [Asset]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, ThumbnailProvider.hdJPEGKey(for: $0).keyString)
        })
    }

    private func solidImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()!
    }

    /// 600×400: 左 100 px 红、右 100 px 蓝、中间 400×400 绿。中心裁切正好只剩绿。
    private func stripeImage(width: Int = 600, height: Int = 400) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let side = height
        let left = (width - side) / 2
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: left, height: height))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: left, y: 0, width: side, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: left + side, y: 0, width: width - side - left, height: height))
        return context.makeImage()!
    }

    private func cache() throws -> ThumbnailCache {
        try ThumbnailCache(root: workDir.appendingPathComponent("thumbs-\(UUID().uuidString)",
                                                                isDirectory: true))
    }

    private func providerWithSquares(for assets: [Asset]) throws -> ThumbnailProvider {
        let cache = try cache()
        for (index, asset) in assets.enumerated() {
            try cache.store(image: solidImage(red: CGFloat(index + 1) / 4, green: 0.3, blue: 0.2),
                            for: ThumbnailProvider.hdJPEGKey(for: asset))
        }
        return ThumbnailProvider(cache: cache)
    }

    private func panel(store: BackgroundTaskStore,
                       provider: ThumbnailProvider) -> BackgroundTasksPopover {
        let panel = BackgroundTasksPopover(
            store: store,
            thumbnailSource: BackgroundTaskThumbnailSource(provider: { provider }))
        panel.loadViewIfNeeded()
        panel.reload()
        return panel
    }

    private func report(_ items: [ExportItem],
                        failures: Set<String> = [],
                        cancelled: Set<String> = []) -> BatchExportReport {
        let outcomes = items.enumerated().map { index, item -> BatchExportOutcome in
            if failures.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0, xmpURL: nil, warnings: [],
                                          error: "fake failure")
            }
            if cancelled.contains(item.id) {
                return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                          fileURL: nil, fileBytes: 0, pixelSize: nil,
                                          seconds: 0, xmpURL: nil, warnings: [],
                                          error: nil, cancelled: true)
            }
            return BatchExportOutcome(index: index, id: item.id, sourceName: item.name,
                                      fileURL: workDir.appendingPathComponent("\(item.id).png"),
                                      fileBytes: 16,
                                      pixelSize: ImageSize(width: 4, height: 4),
                                      seconds: 0.01, xmpURL: nil, warnings: [], error: nil)
        }
        return BatchExportReport(outcomes: outcomes, seconds: 0.01,
                                 requestedConcurrency: 1, peakConcurrency: 1)
    }

    private func pump(_ seconds: TimeInterval = 0.01) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func onlyTask(in store: BackgroundTaskStore) throws -> BackgroundTask {
        let task = try XCTUnwrap(store.tasks.first, "后台面板里没有任务")
        XCTAssertEqual(store.tasks.count, 1, "一次导出只能产生一条任务")
        return task
    }

    // MARK: - ① 三张跑完：行停在第三张，方块还在

    func testAFinishedExportKeepsTheLastPhotosSquare() throws {
        let assets = assets(["a", "b", "c"])
        let keys = thumbKeys(assets)
        let provider = try providerWithSquares(for: assets)
        let store = BackgroundTaskStore()
        let sheet = model(store: store)
        let batchItems = exportItems(assets)
        let finished = expectation(description: "fake export finished")

        sheet.batchRun = { items, preset, _, _, render in
            for item in items {
                _ = try? render(item, preset)
                DispatchQueue.main.sync {}
            }
            finished.fulfill()
            return self.report(items)
        }

        XCTAssertTrue(sheet.run(items: batchItems, thumbKeys: keys))
        wait(for: [finished], timeout: 2)
        waitUntil("导出任务没有 finished") { store.tasks.first?.state == .finished }

        let task = try onlyTask(in: store)
        print("549① asset=\(task.currentAssetID ?? "nil") "
              + "key=\(task.currentThumbKey?.suffix(20) ?? "nil") state=\(task.state)")
        XCTAssertEqual(task.currentAssetID, assets[2].id, "① 结束时行必须停在第三张")
        XCTAssertEqual(task.currentThumbKey, keys[assets[2].id], "① 方块键必须还是第三张")

        let panel = panel(store: store, provider: provider)
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.3)
        XCTAssertEqual(panel.rowThumbnailKeyForTesting(at: 0), keys[assets[2].id],
                       "① 面板画的必须还是第三张的键")
        XCTAssertNotNil(panel.rowThumbnailImageForTesting(at: 0), "① 结束时方块必须是一张真图")
        XCTAssertEqual(panel.rowIsShowingThumbnailPlaceholderForTesting(at: 0), false,
                       "① 结束时方块不许退回占位色")
    }

    // MARK: - ② 第二张运行时取消：停在第 2 张

    func testCancellingWhileTheSecondItemRunsKeepsTheSecondPhotosSquare() throws {
        let assets = assets(["a", "b"])
        let keys = thumbKeys(assets)
        let store = BackgroundTaskStore()
        let sheet = model(store: store)
        let batchItems = exportItems(assets)
        let secondRenderEntered = expectation(description: "second render entered")
        let releaseSecond = DispatchSemaphore(value: 0)

        sheet.imageRenderer = { item, _, _ in
            if item.id == assets[1].id {
                secondRenderEntered.fulfill()
                releaseSecond.wait()
            }
            return Self.displayImage()
        }
        sheet.batchRun = { items, preset, _, _, render in
            _ = try? render(items[0], preset)
            DispatchQueue.main.sync {}
            _ = try? render(items[1], preset)
            DispatchQueue.main.sync {}
            return self.report(items, cancelled: [items[1].id])
        }

        XCTAssertTrue(sheet.run(items: batchItems, thumbKeys: keys))
        wait(for: [secondRenderEntered], timeout: 2)
        let taskID = try onlyTask(in: store).id
        // The start callback hops through main; wait until the row has actually moved to photo 2.
        waitUntil("第 2 张没有成为当前照片") {
            store.tasks.first?.currentAssetID == assets[1].id
        }

        store.cancel(id: taskID)
        releaseSecond.signal()
        waitUntil("取消后的导出没有收尾") { store.tasks.first?.state.isTerminal == true }

        let task = try onlyTask(in: store)
        print("549② state=\(task.state) asset=\(task.currentAssetID ?? "nil") "
              + "key=\(task.currentThumbKey?.suffix(20) ?? "nil")")
        XCTAssertEqual(task.state, .cancelled)
        XCTAssertEqual(task.currentAssetID, assets[1].id, "② 取消时必须停在取消当刻的第 2 张")
        XCTAssertEqual(task.currentThumbKey, keys[assets[1].id], "② 第 2 张的方块键必须保留")
        XCTAssertEqual(BackgroundTaskStore.countText(for: task), "1/2", "② 取消后的回调不许再推进计数")
    }

    // MARK: - ③ 600×400 的图在行里必须是中心裁出的 400×400 方块

    func testTheRowSquareIsACentreCropOfANonSquarePhoto() throws {
        let asset = assets(["wide"])[0]
        let key = ThumbnailProvider.hdJPEGKey(for: asset)
        let cache = try cache()
        try cache.store(image: stripeImage(), for: key)
        let provider = ThumbnailProvider(cache: cache)

        let store = BackgroundTaskStore()
        store.begin(BackgroundTask(kind: .export, title: "导出 1 张", total: 1,
                                   currentThumbKey: key.keyString))
        let panel = panel(store: store, provider: provider)
        _ = panel.rowThumbnailImageForTesting(at: 0)
        pump(0.4)

        let displayed = try XCTUnwrap(panel.rowThumbnailImageForTesting(at: 0),
                                      "③ 行里必须有一张图")
        print("549③ size=\(displayed.size)")
        XCTAssertEqual(displayed.size.width, displayed.size.height, accuracy: 0.01,
                       "③ 方块位图本身必须是 1:1（裁切，不是保留 600×400 的缩放）")

        let image = try XCTUnwrap(cgImage(from: displayed), "③ 读不出 CGImage")
        XCTAssertEqual(image.width, 400, "③ 中心裁切的边长 = min(600, 400)")
        XCTAssertEqual(image.height, 400)
        XCTAssertEqual(image.width, image.height)

        // 四个角都必须落在原图正中的绿色区域；红 / 蓝两条边不能出现。
        let corners = [(2, 2),
                       (image.width - 3, 2),
                       (2, image.height - 3),
                       (image.width - 3, image.height - 3)]
        for (x, y) in corners {
            let color = try rgb(of: image, x: x, y: y)
            XCTAssertGreaterThan(color.green, 0.6, "③ 角 (\(x),\(y)) 应为绿色，实际 \(color)")
            XCTAssertLessThan(color.red, 0.25, "③ 角 (\(x),\(y)) 不该出现左侧红色：\(color)")
            XCTAssertLessThan(color.blue, 0.25, "③ 角 (\(x),\(y)) 不该出现右侧蓝色：\(color)")
        }

        // Sanity: the source really has red / blue edges; the crop is what removed them.
        let source = try XCTUnwrap(ThumbnailCache.decode(try XCTUnwrap(cache.data(for: key))))
        let left = try rgb(of: source, x: 2, y: source.height / 2)
        let right = try rgb(of: source, x: source.width - 3, y: source.height / 2)
        XCTAssertGreaterThan(left.red, 0.6, "③ 源图左缘应为红色")
        XCTAssertLessThan(left.green, 0.4)
        XCTAssertGreaterThan(right.blue, 0.6, "③ 源图右缘应为蓝色")
        XCTAssertLessThan(right.red, 0.4)
    }

    // MARK: - pixel helpers

    private func cgImage(from image: NSImage) -> CGImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private struct RGB: CustomStringConvertible {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        var description: String {
            String(format: "r=%.2f g=%.2f b=%.2f", red, green, blue)
        }
    }

    private func rgb(of image: CGImage, x: Int, y: Int) throws -> RGB {
        let rep = NSBitmapImageRep(cgImage: image)
        let color = try XCTUnwrap(rep.colorAt(x: x, y: y))
        let srgb = try XCTUnwrap(color.usingColorSpace(.deviceRGB))
        return RGB(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }
}
