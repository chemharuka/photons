import XCTest
@testable import PhotonsFileAccess

final class FileAccessTests: XCTestCase {
    func testScopeSurvivesChildAccessAndBalancesExactlyOnce() {
        let root = URL(fileURLWithPath: "/Volumes/Photos")
        var starts = 0, stops = 0
        var access: FileAccess? = FileAccess(url: root, scope: root, start: { _ in starts += 1; return true }, stop: { _ in stops += 1 })
        var child: FileAccess? = access?.appendingTarget(root.appendingPathComponent("frame.dng"))
        access = nil
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 0, "background child access must retain its folder grant")
        XCTAssertEqual(child?.url.lastPathComponent, "frame.dng")
        child = nil
        XCTAssertEqual(stops, 1)
    }

    func testContainerURLDoesNotStopAnUnstartedScope() {
        var stops = 0
        do {
            let url = URL(fileURLWithPath: "/tmp/example")
            let access = FileAccess(url: url, scope: url, start: { _ in false }, stop: { _ in stops += 1 })
            withExtendedLifetime(access) {}
        }
        XCTAssertEqual(stops, 0)
    }

    func testFolderGrantDoesNotMatchSiblingWithSamePrefix() {
        XCTAssertTrue(FileAccessStore.contains("/Pictures", "/Pictures/trip/a.dng"))
        XCTAssertFalse(FileAccessStore.contains("/Pictures", "/Pictures-private/a.dng"))
        XCTAssertTrue(FileAccessStore.contains("/", "/Pictures/a.dng"))
    }

    func testBookmarkPersistsAcrossStoreInstances() throws {
        let name = "Photons.FileAccessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("照片.txt")
        try Data("original".utf8).write(to: file)
        try FileAccessStore(defaults: defaults).rememberSelection(directory)
        let restored = FileAccessStore(defaults: defaults).access(to: file)
        XCTAssertEqual(try String(contentsOf: restored.url, encoding: .utf8), "original")
    }
}
