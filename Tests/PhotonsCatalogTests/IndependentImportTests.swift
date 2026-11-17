import XCTest
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

final class IndependentImportTests:XCTestCase {
    func testOptOutCreatesSeparateEditsAndRatingsForSameOriginal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let file=root.appendingPathComponent("photo.dng")
        try Data((0..<4096).map {UInt8(truncatingIfNeeded:$0)}).write(to:file)
        let catalog=try Catalog.create(at:root.appendingPathComponent("Test.photonslibrary"))
        let service=ImportService(catalog:catalog)
        let first=try service.run(sources:[file],options:.init())
        XCTAssertEqual(first.added,1)
        XCTAssertEqual(try service.run(sources:[file],options:.init()).added,0)
        let copy=try service.run(sources:[file],options:.init(skipDuplicates:false))
        XCTAssertEqual(copy.added,1)
        let a=try XCTUnwrap(first.addedAssetIDs.first),b=try XCTUnwrap(copy.addedAssetIDs.first)
        XCTAssertNotEqual(a,b)
        try catalog.setRating(5,forAsset:a)
        try catalog.dbQueue.write {db in try db.execute(sql:"UPDATE assets SET develop_json=? WHERE id=?",arguments:["{\"independent\":true}",a])}
        let original=try XCTUnwrap(catalog.asset(id:a)),independent=try XCTUnwrap(catalog.asset(id:b))
        XCTAssertEqual(original.contentHash,independent.contentHash)
        XCTAssertEqual(try catalog.fileURL(for:original),try catalog.fileURL(for:independent))
        XCTAssertEqual(independent.rating,0)
        XCTAssertNotEqual(original.developJson,independent.developJson)
        XCTAssertEqual(try catalog.rowCount("asset_history",assetIDs:[a,b]),2)
    }

    func testMigrationPreservesHistoryMetadataAlbumsAndForeignKeys() throws {
        let queue=try DatabaseQueue()
        try Schema.migrate(queue,upTo:6)
        try queue.write {db in
            try db.execute(sql:"INSERT INTO source_roots(id,display_name,path_hint,management_mode,status,created_at) VALUES('r','source','/tmp','reference','online','now')")
            try db.execute(sql:"INSERT INTO assets(id,source_root_id,rel_path,filename,ext,kind,size,mtime,content_hash,imported_at,rating,develop_json) VALUES('a','r','p.dng','p.dng','dng','raw',10,0,'hash','now',4,'saved edits')")
            try db.execute(sql:"INSERT INTO asset_metadata(asset_id) VALUES('a')")
            try db.execute(sql:"INSERT INTO albums(id,name,created_at) VALUES('album','Favorites','now')")
            try db.execute(sql:"INSERT INTO album_assets(album_id,asset_id) VALUES('album','a')")
            try db.execute(sql:"INSERT INTO asset_history(asset_id,seq,develop_json,label,created_at) VALUES('a',1,'saved edits','edit','now')")
        }
        try Schema.migrate(queue)
        try Schema.migrate(queue)
        try queue.write {db in
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT rating FROM assets WHERE id='a'"),4)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT develop_json FROM asset_history WHERE asset_id='a'"),"saved edits")
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM asset_metadata"),1)
            XCTAssertEqual(try String.fetchOne(db,sql:"SELECT asset_id FROM album_assets WHERE album_id='album'"),"a")
            XCTAssertTrue(try Row.fetchAll(db,sql:"PRAGMA foreign_key_check").isEmpty)
            try db.execute(sql:"INSERT INTO assets(id,source_root_id,rel_path,filename,ext,kind,size,mtime,content_hash,imported_at) VALUES('b','r','p.dng','p.dng','dng','raw',10,0,'hash','now')")
            XCTAssertEqual(try Int.fetchOne(db,sql:"SELECT count(*) FROM assets"),2)
        }
    }
}
