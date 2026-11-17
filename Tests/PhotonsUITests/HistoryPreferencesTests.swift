import XCTest
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

@MainActor
final class HistoryPreferencesTests:XCTestCase {
    func testPreferenceChoicesPersistAndInvalidValuesFallBack() throws {
        let name="history-preferences-\(UUID())",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer {defaults.removePersistentDomain(forName:name)}
        let preferences=ApplicationPreferences(defaults:defaults)
        XCTAssertEqual(preferences.historyDepth,20)
        for depth in [10,20,50,100] {
            preferences.historyDepth=depth
            XCTAssertEqual(ApplicationPreferences(defaults:defaults).historyDepth,depth)
        }
        preferences.historyDepth=99
        XCTAssertEqual(preferences.historyDepth,20)
        defaults.set(-1,forKey:ApplicationPreferences.Key.historyDepth)
        XCTAssertEqual(ApplicationPreferences(defaults:defaults).historyDepth,20)
    }

    func testImportStateSurvivesHistoryLimitAndResetIsUndoableAfterReopen() throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let name="history-limit-\(UUID())",defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer {defaults.removePersistentDomain(forName:name)}
        let preferences=ApplicationPreferences(defaults:defaults)
        let url=folder.appendingPathComponent("History.photonslibrary"),catalog=try Catalog.create(at:url)
        let root=try catalog.ensureRoot(for:folder,mode:.reference)
        let asset=Asset(sourceRootId:root.id,relPath:"original.dng",filename:"original.dng",ext:"dng",kind:.raw,size:1,mtime:0,contentHash:"original")
        try catalog.dbQueue.write {try asset.insert($0)}
        var imported=EditModel.neutral;imported.light.temperature=4100;imported.light.exposure=0.25
        _ = try catalog.saveDevelop(imported,history:EditHistory(baseline:imported),forAsset:asset.id)
        let session=CatalogSession(remembersRecentLibrary:false,preferences:preferences)
        try session.open(url);session.selectOnly(asset.id)
        for i in 1...35 {
            session.applyEdit {$0.light.exposure=Double(i)/20}
            XCTAssertTrue(session.commitEdit(label:"Exposure \(i)",coalesce:false))
        }
        XCTAssertEqual(session.history.count,20)
        XCTAssertEqual(session.importedEdit,imported)
        preferences.historyDepth=10
        XCTAssertEqual(session.history.count,10)
        let before=session.edit
        XCTAssertTrue(session.resetToImportedState())
        XCTAssertEqual(session.edit,imported)
        XCTAssertTrue(session.undo());XCTAssertEqual(session.edit,before)
        XCTAssertTrue(session.redo());XCTAssertEqual(session.edit,imported)
        let reopened=CatalogSession(remembersRecentLibrary:false,preferences:preferences)
        try reopened.open(url);reopened.selectOnly(asset.id)
        XCTAssertEqual(reopened.history.count,10)
        XCTAssertEqual(reopened.edit,imported)
        XCTAssertEqual(reopened.importedEdit,imported)
        XCTAssertNil(reopened.lastPersistError)
        // Shrinking while the cursor is near the beginning must not change the photo.
        preferences.historyDepth=100
        let wide=CatalogSession(remembersRecentLibrary:false,preferences:preferences)
        try wide.open(url);wide.selectOnly(asset.id)
        for _ in 0..<25 {_ = wide.undo()}
        let undone=wide.edit
        preferences.historyDepth=10
        XCTAssertEqual(wide.edit,undone);XCTAssertEqual(wide.history.current,undone)
        wide.applyEdit {$0.light.contrast=0.1}
        XCTAssertTrue(wide.commitEdit(label:"Contrast",coalesce:false))
        XCTAssertNil(wide.lastPersistError)
    }
}
