import XCTest
import AppKit
import CoreGraphics
import ImageIO
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 444 / §20 P1 — 呈现状态**只写不读**：先钉住「状态写得对」。
///
/// 单元用例把 `CanvasPresentation` 自己的语义钉死（同值不转移、`hold` 不清 `content`、
/// placeholder → frame 的三步顺序）；端到端用例走真库、真解码、真 present，只用
/// `presentationForTesting.transitions` 读回序列。
@MainActor
final class CanvasPresentationTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var cacheDirs: [URL] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-presentation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for dir in cacheDirs { try? FileManager.default.removeItem(at: dir) }
        cacheDirs.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - the state machine's own rules

    private func texture() throws -> MTLTexture {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        descriptor.usage = [.shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor), "no texture")
    }

    func testShowRecordsOnlyRealTransitions() throws {
        var presentation = CanvasPresentation()
        XCTAssertEqual(presentation.content.label, "empty")

        // 同值重复 show：不产生转移。
        presentation.show(.empty, reason: "same")
        XCTAssertTrue(presentation.transitions.isEmpty)

        let thumb = ThumbFrame(photo: "B", pixelSize: ImageSize(width: 640, height: 427))
        presentation.show(.placeholder(thumb), reason: "standin")
        let first = try texture()
        let second = try texture()
        presentation.show(.frame(OwnedCanvasTexture(texture: first, owner: .borrowed), settled: false),
                          reason: "present")
        presentation.show(.frame(OwnedCanvasTexture(texture: second, owner: .borrowed), settled: true),
                          reason: "present")

        XCTAssertEqual(presentation.transitions.map(\.to),
                       ["placeholder(B)", "frame(settled:false)", "frame(settled:true)"])
        XCTAssertEqual(presentation.transitions.map(\.reason),
                       ["standin", "present", "present"])

        // 同一张纹理、同一个 settled 标记：即使 owner 重新包一层也是同一个内容。
        presentation.show(.frame(OwnedCanvasTexture(texture: second, owner: .borrowed), settled: true),
                          reason: "same")
        XCTAssertEqual(presentation.transitions.count, 3)
    }

    func testHoldDoesNotClearContentAndIgnoresTheSameTexture() throws {
        var presentation = CanvasPresentation()
        presentation.show(.placeholder(ThumbFrame(photo: "B", pixelSize: nil)), reason: "standin")

        let held = OwnedCanvasTexture(texture: try texture(), owner: .borrowed)
        presentation.hold(held, reason: "gesture")
        XCTAssertEqual(presentation.content.label, "placeholder(B)")
        XCTAssertTrue(presentation.held?.texture === held.texture)
        let count = presentation.transitions.count

        presentation.hold(OwnedCanvasTexture(texture: held.texture, owner: .borrowed),
                          reason: "gesture")
        XCTAssertEqual(presentation.transitions.count, count,
                       "the same texture held twice is not a transition")

        presentation.hold(nil, reason: "gesture")
        XCTAssertNil(presentation.held)
        XCTAssertEqual(presentation.content.label, "placeholder(B)",
                       "dropping the held texture must not clear what is on the canvas")
        XCTAssertEqual(presentation.transitions.count, count + 1)
    }

    // MARK: - end to end: a real library, a real photo, a real present

    func testOpeningAPhotoRecordsPlaceholderThenFrame() throws {
        let raw = try rawFixture()
        let library = try makeLibrary(photos: [raw])
        let editor = EditorWindowController(size: NSSize(width: 1100, height: 760))
        windows.append(try XCTUnwrap(editor.window))
        try editor.openLibrary(at: library.package)
        let loupe = editor.rootView.loupeController
        let cache = try XCTUnwrap(editor.session.thumbnailCache, "the library has no thumbnail cache")
        for asset in library.assets { try seedPreview(asset, cache: cache) }

        editor.session.selectOnly(library.assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil },
                      "no first frame (last error: \(loupe.lastPresentError ?? "—"))")
        XCTAssertTrue(waitFor(10) {
            loupe.presentationForTesting.transitions.contains { $0.to.hasPrefix("frame(") }
        }, "the frame present never wrote a transition")

        let contents = loupe.presentationForTesting.transitions.map(\.to)
        let placeholder = try XCTUnwrap(contents.firstIndex { $0.hasPrefix("placeholder(") },
                                        "no placeholder transition: \(contents)")
        let frame = try XCTUnwrap(contents.firstIndex { $0.hasPrefix("frame(") },
                                  "no frame transition: \(contents)")
        XCTAssertLessThan(placeholder, frame,
                          "the stand-in must be written before the frame that replaces it: \(contents)")

        let cacheCopies = contents.filter { $0 == "frame(settled:false)" }
        let settled = contents.filter { $0 == "frame(settled:true)" }
        XCTAssertTrue(!cacheCopies.isEmpty || !settled.isEmpty,
                      "a frame transition must say whether it is settled: \(contents)")
        if let firstCache = contents.firstIndex(of: "frame(settled:false)"),
           let firstSettled = contents.firstIndex(of: "frame(settled:true)") {
            XCTAssertLessThan(firstCache, firstSettled,
                              "a cached copy precedes the render it stands in for: \(contents)")
        }
    }

    // MARK: - fixtures

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private struct Library {
        let package: URL
        let assets: [Asset]
    }

    private func makeLibrary(photos: [URL]) throws -> Library {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Presentation.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, photo) in photos.enumerated() {
            let name = "present\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: photo)
            let size = try pixelSize(of: photo)
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)', \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-20T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return Library(package: package, assets: assets)
    }

    /// A small, aspect-correct JPEG under the legacy preview key `armFirstFramePlaceholder` reads, so
    /// the end-to-end run has a stand-in to write without waiting for a RAW thumbnail development.
    private func seedPreview(_ asset: Asset, cache: ThumbnailCache) throws {
        let width = 640, height = 427
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let tier = ThumbnailProvider.effectiveTier(requested: .t1024, ext: asset.ext).tier
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: tier))
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return ImageSize(width: width, height: height)
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }
}
