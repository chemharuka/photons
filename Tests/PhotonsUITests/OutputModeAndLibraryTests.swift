import XCTest
import PhotonsExport
@testable import PhotonsUI

@MainActor final class OutputModeAndLibraryTests:XCTestCase {
    final class DraftStore:ExportDraftPersistence.Store {
        var data:[String:Data]=[:]
        func exportDraftData(forKey key:String)->Data? {data[key]}
        func setExportDraftData(_ value:Data?,forKey key:String) {data[key]=value}
    }
    final class HistoryStore:RecentLibrary.Store {
        var values:[String:String]=[:]
        func string(forKey key:String)->String? {values[key]}
        func set(_ value:String?,forKey key:String) {values[key]=value}
    }
    func testTabsKeepSeparateRecipesAndDNGStaysInHDR() {
        let store=DraftStore(),model=ExportSheetModel(draftStore:store)
        model.allowsLinearDNG=true;model.usesLinearDNG=true
        model.preset.quality=0.91;model.preset.subfolder="HDR"
        model.selectOutputTab(hdr:false)
        XCTAssertFalse(model.hdrEnabled);XCTAssertFalse(model.usesLinearDNG)
        model.selectFormat(.tiff);model.preset.subfolder="SDR";model.preset.quality=0.8
        XCTAssertEqual(model.preset.sdrToneMapping,.standard)
        model.selectOutputTab(hdr:true)
        XCTAssertTrue(model.hdrEnabled);XCTAssertTrue(model.usesLinearDNG)
        XCTAssertEqual(model.preset.subfolder,"HDR");XCTAssertEqual(model.preset.quality,0.91)
        model.selectOutputTab(hdr:false)
        XCTAssertEqual(model.preset.format,.tiff);XCTAssertEqual(model.preset.subfolder,"SDR")
        XCTAssertFalse(model.effectivePreset.isHDR)
        model.preset.sdrToneMapping = .none
        XCTAssertEqual(model.effectivePreset.sdrToneMapping,.standard)
        model.saveDraftOnClose()
        let restored=ExportSheetModel(draftStore:store)
        restored.selectOutputTab(hdr:true)
        XCTAssertEqual(restored.preset.subfolder,"HDR")
        restored.selectOutputTab(hdr:false)
        XCTAssertEqual(restored.preset.format,.tiff)
    }
    func testHistoryDeduplicatesAllOpenedLibrariesAndRemovalKeepsFiles() throws {
        let store=HistoryStore(),folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let a=folder.appendingPathComponent("A.photonslibrary"),b=folder.appendingPathComponent("B.photonslibrary")
        try FileManager.default.createDirectory(at:a,withIntermediateDirectories:true)
        RecentLibrary.remember(a,in:store);RecentLibrary.remember(b,in:store);RecentLibrary.remember(a,in:store)
        XCTAssertEqual(LibraryHistory.entries(in:store).map(\.path),[a.path,b.path])
        LibraryHistory.remove(a,in:store)
        XCTAssertTrue(FileManager.default.fileExists(atPath:a.path))
        XCTAssertEqual(LibraryHistory.entries(in:store).map(\.path),[b.path])
    }
}
