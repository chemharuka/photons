import XCTest
import CoreImage
import ImageIO
import CryptoKit
import UIKit
import PhotonsCore
import PhotonsCatalog
import PhotonsPanorama
@testable import PhotonsMobile
@testable import PhotonsExtensions

final class IPadEngineTests: XCTestCase {
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ipad-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }
    private func engine() -> MobileEngine { MobileEngine(libraryURL: folder.appendingPathComponent("Test.photonslibrary")) }

    func testLensProfileDetailsPreserveCaptureMetadataAndCoverage() async throws {
        let engine = engine(), profiles = try await engine.profiles()
        let summary = try XCTUnwrap(profiles.first { $0.id == LCCLensProfile.builtInID })
        let profile = try await engine.profile(summary.id)
        try profile.validate()
        XCTAssertEqual(summary.captureCount,profile.captures.count)
        XCTAssertFalse(profile.notes.isEmpty); XCTAssertNotNil(LCCProfileSummary(profile).calibrationBody)
        for orientation in profile.orientations {
            let captures = profile.captures(for: orientation), bounds = MobileProfileCoverage.bounds(profile.captures(for: orientation))
            XCTAssertFalse(bounds.isNull)
            for capture in captures { XCTAssertTrue(bounds.contains(capture.fieldRect)); XCTAssertGreaterThan(capture.grid.width,1); XCTAssertGreaterThan(capture.pixelWidth,0) }
        }
    }

    func testClearCacheKeepsLibraryOriginalsEditsFoldersAndProfiles() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("clear-cache"))
        let group = try await engine.createFolder("Keep")
        _ = try await engine.importPhotos(urls,skipDuplicates: true,folder: group.id,progress: { _,_ in })
        let photos = try await engine.photos(), photo = try XCTUnwrap(photos.first)
        let original = try Data(contentsOf: photo.url)
        var edit = EditModel.neutral; edit.light.exposure = 0.8
        try await engine.save(edit,history: .init(baseline: edit),id: photo.id)
        let profiles = try await engine.profiles()
        let export = folder.appendingPathComponent("Test.photonslibrary/Exports/keep.txt")
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(),withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: export)
        _ = try await engine.frame(photo,edit: edit,hdr: true)
        let before = try await engine.cacheUsage(); XCTAssertGreaterThan(before.diskBytes,0); XCTAssertGreaterThan(before.memoryBytes,0)
        try await engine.clearPreviewCache()
        let after = try await engine.cacheUsage(); XCTAssertEqual(after.diskBytes,0); XCTAssertEqual(after.memoryBytes,0); XCTAssertEqual(after.files,0)
        XCTAssertEqual(try Data(contentsOf: photo.url),original); XCTAssertEqual(try Data(contentsOf: export),Data("keep".utf8))
        let stored = try await engine.edit(photo.id), folders = try await engine.folderIndex(), remainingProfiles = try await engine.profiles()
        XCTAssertEqual(stored.light.exposure,0.8); XCTAssertEqual(folders.assignments[photo.id],group.id); XCTAssertEqual(profiles,remainingProfiles)
        let count = await engine.renderCount
        _ = try await engine.frame(photo,edit: edit,hdr: true)
        let regenerated = await engine.renderCount; XCTAssertEqual(regenerated,count+1)
    }

    func testPairedPreviewCacheSurvivesToggleRestartAndInvalidatesEdits() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("cache"))
        let photo = MobilePhoto(id: "cache",name: "cache",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral; edit.light.exposure = 2
        let hdr = try await engine.frame(photo,edit: edit,hdr: true)
        let count = await engine.renderCount
        let sdr = try await engine.frame(photo,edit: edit,hdr: false)
        let again = try await engine.frame(photo,edit: edit,hdr: true)
        let afterToggle = await engine.renderCount
        XCTAssertEqual(count,afterToggle); XCTAssertTrue(again.image === hdr.image)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        for i in 0..<8 { var e = edit; e.light.exposure = Double(i)/10; _ = try await engine.frame(photo,edit: e,hdr: false,edge: 320) }
        let afterWarming = await engine.renderCount
        _ = try await engine.frame(photo,edit: edit,hdr: false)
        let afterFull = await engine.renderCount; XCTAssertEqual(afterWarming,afterFull)
        let reopened = self.engine()
        let disk = try await reopened.frame(photo,edit: edit,hdr: true)
        let diskCount = await reopened.renderCount
        XCTAssertEqual(diskCount,0); XCTAssertEqual(disk.histogram,hdr.histogram)
        XCTAssertEqual(disk.image.dataProvider?.data,hdr.image.dataProvider?.data)
        edit.light.exposure = 2.5
        _ = try await reopened.frame(photo,edit: edit,hdr: false)
        let editedCount = await reopened.renderCount; XCTAssertEqual(editedCount,1)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)],ofItemAtPath: photo.url.path)
        _ = try await reopened.frame(photo,edit: edit,hdr: true)
        let replacedCount = await reopened.renderCount; XCTAssertEqual(replacedCount,2)
        let request = MobileDetailRequest(rect: CGRect(x: 0.2,y: 0.2,width: 0.4,height: 0.4),scale: 1)
        let detail = try await reopened.detail(photo,edit: edit,hdr: true,request: request)
        let beforeDetailToggle = await reopened.renderCount
        let detailSDR = try await reopened.detail(photo,edit: edit,hdr: false,request: request)
        let afterDetailToggle = await reopened.renderCount
        XCTAssertEqual(beforeDetailToggle,afterDetailToggle); XCTAssertEqual(detail.rect,detailSDR.rect)
        var memory = MobilePreviewMemoryCache(budget: 2*(hdr.image.bytesPerRow*hdr.image.height+sdr.image.bytesPerRow*sdr.image.height))
        let pair = MobilePreviewPair(hdr: hdr,sdr: sdr)
        memory.put(pair,key: "a"); memory.put(pair,key: "b"); _ = memory.get("a"); memory.put(pair,key: "c")
        XCTAssertNil(memory.get("b")); XCTAssertNotNil(memory.get("a")); XCTAssertLessThanOrEqual(memory.bytes,memory.budget)
        let directory = folder.appendingPathComponent("Test.photonslibrary/MobilePreviews")
        for url in try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil) { try Data("broken".utf8).write(to: url) }
        let corruptReader = self.engine()
        _ = try await corruptReader.frame(photo,edit: edit,hdr: false)
        let fallbackCount = await corruptReader.renderCount; XCTAssertEqual(fallbackCount,1)
    }

    func testLegacyPreviewIsRegeneratedAfterEngineUpgrade() async throws {
        let producer = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("upgrade"))
        let photo = MobilePhoto(id: "upgrade",name: "upgrade",url: urls[0],rating: 0,width: 768,height: 512)
        let edit = EditModel.neutral
        _ = try await producer.frame(photo,edit: edit,hdr: true)
        let directory = folder.appendingPathComponent("Test.photonslibrary/MobilePreviews")
        let records = try FileManager.default.contentsOfDirectory(at: directory,includingPropertiesForKeys: nil)
        XCTAssertEqual(records.count,1)
        let record = try XCTUnwrap(records.first)
        // Re-create the actual pre-upgrade disk filename, with a valid pair payload. An app
        // upgrade must miss this entry rather than accept obsolete but decodable pixels.
        let attributes = try FileManager.default.attributesOfItem(atPath: photo.url.path)
        let source = "\(photo.url.path):\((attributes[.size] as? NSNumber)?.int64Value ?? 0):\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let legacy = SHA256.hash(data: Data("ipad-v3-pair:\(photo.id):\(source):1600:".utf8) + (try encoder.encode(edit)))
            .map { String(format: "%02x",$0) }.joined()
        let oldURL = directory.appendingPathComponent(legacy + ".pair")
        try FileManager.default.moveItem(at: record,to: oldURL)
        let upgraded = engine()
        _ = try await upgraded.frame(photo,edit: edit,hdr: false)
        let renders = await upgraded.renderCount
        XCTAssertEqual(renders,1,"An old algorithm's preview must be regenerated")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldURL.path),"Disposable old entries remain under normal size pruning")
        let reopened = engine()
        _ = try await reopened.frame(photo,edit: edit,hdr: true)
        let reused = await reopened.renderCount
        XCTAssertEqual(reused,0,"Current-generation pairs remain reusable across launches and HDR/SDR")
    }

    func testPanoramaDisplayModeReusesCompositePreview() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("pano-cache"))
        let photos = urls.map { MobilePhoto(id: $0.lastPathComponent,name: $0.lastPathComponent,url: $0,rating: 0,width: 768,height: 512) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        let first = try await engine.frame(plan,hdr: true)
        _ = try await engine.frame(plan,hdr: false)
        let again = try await engine.frame(plan,hdr: true)
        let count = await engine.panoramaPreviewCount
        XCTAssertEqual(count,1); XCTAssertTrue(first.image === again.image)
    }

    func testHistogramAdditiveBandsAndPixelCoverageKeepNeutralPeaks() {
        let bands = MobileHistogramReading.bands(tops: [20,40,60],bottom: 100)
        XCTAssertEqual(bands.map(\.mask),[7,3,1]) // white, yellow, red; no channel exceeds 1.
        XCTAssertEqual(bands.map(\.height),[40,20,20])
        let neutral = MobileHistogramReading.bands(tops: [25,25,25],bottom: 100).filter { $0.height > 0 }
        XCTAssertEqual(neutral.count,1); XCTAssertEqual(neutral.first?.mask,7)
        let points = [CGPoint(x: 0,y: 100),CGPoint(x: 0.5,y: 10),CGPoint(x: 1,y: 100)]
        var cursor = 0
        XCTAssertEqual(MobileHistogramReading.top(points,from: 0.2,to: 0.8,cursor: &cursor),10)
        XCTAssertEqual(MobileHistogramReading.top(points,from: 0.8,to: 1,cursor: &cursor),64,accuracy: 0.0001)
        XCTAssertTrue(MobileHistogramReading.bin(at: 0.75).tail,"HDR/SDR use the same fixed axis")
    }

    func testHistogramAxisAndDisplayClippingMatchMacSemantics() throws {
        XCTAssertEqual(MobileHistogramReading.bin(at: 0.25).index,128)
        XCTAssertTrue(MobileHistogramReading.bin(at: 0.5).tail)
        XCTAssertEqual(MobileHistogramReading.bin(at: 0.75).index,128)
        XCTAssertEqual(MobileHistogramReading.bin(at: 1).index,255)
        let sample = LinearSample(width: 3,height: 1,rgba: [0,0,0,1, 1,1,1,1, 4,4,4,1])
        let histogram = HistogramSnapshot(sample: sample,canvas: ImageSize(width: 300,height: 100)).hdr
        XCTAssertEqual(histogram.luma.clippedLow,1.0/3,accuracy: 0.001)
        XCTAssertGreaterThan(histogram.withDisplayHeadroom(1).luma.clippedCeiling,histogram.withDisplayHeadroom(8).luma.clippedCeiling)
        XCTAssertEqual(histogram.withDisplayHeadroom(1).binsDigest(),histogram.withDisplayHeadroom(8).binsDigest())
        XCTAssertEqual(MobileHistogramReading.percent(0.0001),"<0.1%")
    }

    func testSingleLibraryFoldersPersistWithoutChangingOriginalsOrEdits() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("folder-samples"))
        let first = try await engine.createFolder("Travel"), second = try await engine.createFolder("Studio")
        _ = try await engine.importPhotos(urls,skipDuplicates: true,folder: first.id,progress: { _,_ in })
        let photos = try await engine.photos(), photo = try XCTUnwrap(photos.first)
        let original = try Data(contentsOf: photo.url)
        var edit = EditModel.neutral; edit.light.exposure = 0.7
        try await engine.save(edit,history: .init(baseline: edit),id: photo.id)
        try await engine.movePhotos([photo.id],to: second.id)
        try await engine.renameFolder(second.id,to: "Portraits")
        let reopened = self.engine(), index = try await reopened.folderIndex()
        XCTAssertEqual(index.assignments[photo.id],second.id)
        XCTAssertEqual(index.folders.first { $0.id == second.id }?.name,"Portraits")
        XCTAssertEqual(index.assignments.count,3)
        try await reopened.removeFolder(second.id)
        let removed = try await reopened.folderIndex(), saved = try await reopened.edit(photo.id)
        XCTAssertNil(removed.assignments[photo.id]); XCTAssertEqual(saved.light.exposure,0.7)
        XCTAssertEqual(try Data(contentsOf: photo.url),original)
        do { _ = try await engine.createFolder(" travel "); XCTFail("Duplicate names must be rejected") } catch { }
        do { _ = try await engine.importPhotos([folder.appendingPathComponent("Other.photonslibrary")],skipDuplicates: true,progress: { _,_ in }); XCTFail("Must not import another library") } catch { }
        let remaining = try await reopened.photos(); XCTAssertEqual(remaining.count,3)
    }

    func testZoomDetailMatchesEditedFullResolutionPixels() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("detail-samples"))
        let photo = MobilePhoto(id: "detail",name: "detail",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral
        edit.light.exposure = 0.6; edit.geometry.quarterTurns = 1
        edit.geometry.crop = .init(x: 0.125,y: 0.125,width: 0.75,height: 0.75)
        let full = try await engine.frame(photo,edit: edit,hdr: true,edge: 0)
        let request = MobileDetailRequest(rect: CGRect(x: 0.25,y: 0.25,width: 0.5,height: 0.5),scale: 1)
        let detail = try await engine.detail(photo,edit: edit,hdr: true,request: request)
        let rect = CGRect(x: detail.rect.minX*Double(full.image.width),y: detail.rect.minY*Double(full.image.height),width: Double(detail.image.width),height: Double(detail.image.height))
        let expected = try XCTUnwrap(full.image.cropping(to: rect))
        let actualData = try XCTUnwrap(detail.image.dataProvider?.data) as Data
        let expectedData = try XCTUnwrap(expected.dataProvider?.data) as Data
        var largest = 0.0
        let x0 = Int(request.rect.minX * Double(full.image.width) - rect.minX)
        let y0 = Int(request.rect.minY * Double(full.image.height) - rect.minY)
        let x1 = min(detail.image.width,Int(request.rect.maxX * Double(full.image.width) - rect.minX))
        let y1 = min(detail.image.height,Int(request.rect.maxY * Double(full.image.height) - rect.minY))
        for y in y0..<y1 {
            for x in (x0*4)..<(x1*4) {
                let a = actualData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y*detail.image.bytesPerRow+x*2,as: UInt16.self) }
                let b = expectedData.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: y*expected.bytesPerRow+x*2,as: UInt16.self) }
                largest = max(largest,abs(Double(Float16(bitPattern: a))-Double(Float16(bitPattern: b))))
            }
        }
        XCTAssertLessThan(largest,0.015,"Zoom must render the same edited pixels, including crop and rotation, not rescale the fit preview")
        XCTAssertLessThan(detail.image.width,full.image.width)
        XCTAssertEqual(MobileZoomGeometry.fit(pixels: CGSize(width: 4000,height: 3000),viewport: CGSize(width: 1000,height: 750),screenScale: 2),0.5)
        XCTAssertNil(MobileZoomGeometry.validPercent("nan")); XCTAssertNil(MobileZoomGeometry.validPercent("0"))
        XCTAssertEqual(MobileZoomGeometry.validPercent("150"),1.5)
    }

    @MainActor
    func testClosingPanoramaDiscardsTransientPreviewAndRestoresView() async throws {
        let model = MobileWorkspaceModel()
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("close-samples"))
        let photos = urls.map { MobilePhoto(id: $0.lastPathComponent,name: $0.lastPathComponent,url: $0,rating: 0,width: 768,height: 512) }
        let original = try await engine.frame(photos[0],edit: .neutral,hdr: false,edge: 256)
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        model.active = photos[0]; model.thumbnails[photos[0].id] = original
        model.beginPanorama(); model.plan = plan; model.showGrid = false
        model.frame = try await engine.frame(plan,hdr: false)
        model.setPanoramaTone(.panoramaDefault) // pending asynchronous preview must not resurrect it
        model.endPanorama()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(model.plan); XCTAssertNil(model.manifest)
        XCTAssertTrue(model.showGrid)
        XCTAssertTrue(model.frame?.image === original.image)
        XCTAssertFalse(model.rendering)
        model.endPanorama() // repeated dismissal is harmless
        XCTAssertTrue(model.showGrid)
    }

    func testImportDuplicatesRenderAndPersistentHistory() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        let first = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        XCTAssertEqual(first.added, 3)
        let duplicate = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        XCTAssertEqual(duplicate.added, 0)
        let copies = try await engine.importPhotos([urls[0]], skipDuplicates: false, progress: { _,_ in })
        XCTAssertEqual(copies.added, 1)
        let photos = try await engine.photos()
        XCTAssertEqual(photos.count, 4)
        let photo = try XCTUnwrap(photos.first)
        var edit = EditModel.neutral
        let original = try await engine.frame(photo, edit: edit, hdr: false, edge: 256)
        XCTAssertGreaterThan(try XCTUnwrap(original.histogram).sampleCount, 0)
        edit.light.exposure = 1.0
        let changed = try await engine.frame(photo, edit: edit, hdr: false, edge: 256)
        XCTAssertNotEqual(original.histogram?.binsDigest(), changed.histogram?.binsDigest())
        var history = EditHistory(baseline: .neutral)
        history.commit(edit, label: "Exposure", coalesce: false)
        try await engine.save(edit, history: history, id: photo.id)
        let reopened = self.engine()
        let saved = try await reopened.edit(photo.id)
        XCTAssertEqual(saved.light.exposure, 1)
        var savedHistory = try await reopened.history(photo.id)
        XCTAssertEqual(savedHistory.undo()?.light.exposure, 0)
        let thumb = try await engine.thumbnail(photo, hdr: false)
        let cached = try await reopened.thumbnail(photo, hdr: false)
        XCTAssertEqual(thumb.histogram, cached.histogram)
        XCTAssertEqual(thumb.image.width, cached.image.width)
    }

    func testPanoramaAlignmentScaledLosslessExportAndMetadata() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        _ = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        let photos = try await engine.photos()
        var options = PanoramaOptions(); options.matchExposure = false; options.avoidMotion = false
        let plan = try await engine.analyze(photos, options: options, positions: [:], sensor: nil,
                                           cancellation: .init(), progress: { _,_ in })
        XCTAssertEqual(plan.sources.count, 3)
        XCTAssertEqual(plan.size.width, 1208, accuracy: 3)
        XCTAssertEqual(plan.size.height, 512, accuracy: 3)
        XCTAssertEqual(plan.origins[1].x - plan.origins[0].x, 220, accuracy: 2)
        let composite = try PanoramaEngine().renderComposite(plan, outputLongEdge: 604)
        XCTAssertEqual(composite.extent.width, 604, accuracy: 1)
        XCTAssertEqual(composite.extent.height, 256, accuracy: 1)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 604
        let output = try await engine.export(photo: nil, edit: .neutral, plan: plan, manifest: nil, settings: settings,
                                             cancellation: .init(), progress: { _,_ in })
        XCTAssertTrue(output.lastPathComponent.hasPrefix("Sample-01_pano"))
        let manifest = try XCTUnwrap(PanoramaManifest.read(from: output))
        XCTAssertEqual(manifest.frames.count, 3)
        XCTAssertEqual(manifest.canvas.width, plan.size.width)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any])
        // IFD0 is the embedded preview; CIRAWFilter resolves the full-resolution SubIFD.
        XCTAssertEqual(try PanoramaSource(url: output).size.width, 604, accuracy: 1)
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        XCTAssertEqual((tiff?[kCGImagePropertyTIFFCompression as String] as? NSNumber)?.intValue, 7)
        settings.longEdge = 0
        let full = try await engine.export(photo: nil,edit: .neutral,plan: plan,manifest: nil,settings: settings,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try PanoramaSource(url: full).size,plan.outputSize,"Full resolution must not silently retain a long-edge cap")
        let imported = try await engine.photos()
        XCTAssertEqual(imported.count, 5)
        let frame = try await engine.frame(plan, hdr: false)
        XCTAssertNotNil(frame.histogram)
        // A resized/cropped ordinary export of a reimported DNG must keep its original stitch geometry.
        let reimported = try XCTUnwrap(imported.first { $0.name == output.lastPathComponent })
        var cropEdit = EditModel.neutral; cropEdit.geometry.crop = .init(x: 0.25,y: 0.125,width: 0.5,height: 0.75)
        settings.format = "tiff"; settings.hdr = false; settings.longEdge = 160
        let copy = try await engine.export(photo: reimported,edit: cropEdit,plan: nil,manifest: nil,settings: settings,
                                          cancellation: .init(),progress: { _,_ in })
        let carried = try XCTUnwrap(PanoramaManifest.read(from: copy))
        XCTAssertEqual(carried.frames.count,3)
        let point = carried.canvasPoint(u: 0.25,v: 0.5)
        XCTAssertEqual(point.x,0.375,accuracy: 1e-8); XCTAssertEqual(point.y,0.5,accuracy: 1e-8)
    }

    func testTraditionalAndProfileLCCUseTheSharedPipeline() async throws {
        let flat = try makeFlat(name: "flat.dng", exposure: 1)
        let scene = try makeFlat(name: "scene.dng", exposure: 0.5)
        let source = try PanoramaSource(url: scene, sensorOverride: .init(width: 36,height: 24,source: "Generated fixture"))
        XCTAssertNotNil(source.sensor)
        let corrected = try LCCCorrectionEngine.traditional(scene: source, flatURL: flat)
        XCTAssertNotNil(corrected.preview)
        XCTAssertTrue(try XCTUnwrap(corrected.lccState).complete)
        var calibration = try LCCCreationFrame(url: flat); calibration.shiftConfirmed = true
        let sensor = try XCTUnwrap(source.sensor)
        let profile = try LCCProfileBuilder.create(name: "Generated calibration", aperture: nil, notes: "Test fixture", frames: [calibration],
            sensorLongEdge: max(sensor.width, sensor.height), sensorShortEdge: min(sensor.width, sensor.height))
        let roundTrip = try LCCProfileCodec.decode(LCCProfileCodec.encode(profile))
        let fromProfile = try LCCCorrectionEngine.single(scene: source, profile: roundTrip, position: .zero, refine: false)
        XCTAssertEqual(fromProfile.position, .zero)
        XCTAssertEqual(fromProfile.plan.preview?.width, corrected.preview?.width)
        let context = CIContext()
        let preview = CIImage(cgImage: try XCTUnwrap(fromProfile.plan.preview))
        var sample = [Float](repeating: 0, count: 9 * 4)
        context.render(preview.transformed(by: .init(scaleX: 3 / preview.extent.width, y: 3 / preview.extent.height)),
            toBitmap: &sample, rowBytes: 3 * 16, bounds: CGRect(x: 0,y: 0,width: 3,height: 3), format: .RGBAf,
            colorSpace: PanoramaEngine.linearSpace)
        XCTAssertLessThan(abs(sample[1] - sample[4 * 4 + 1]), 0.08, "LCC should flatten the generated falloff")
    }

    func testLCCCoverageCropUpdatesPreviewExportAndCanBeRemoved() async throws {
        let flat = try makeFlat(name: "crop-flat.dng", exposure: 1)
        let scene = try makeFlat(name: "crop-scene.dng", exposure: 0.5)
        let sensor = SensorSize(width: 36,height: 24,source: "Generated fixture")
        let source = try PanoramaSource(url: scene,sensorOverride: sensor)
        var calibration = try LCCCreationFrame(url: flat); calibration.shiftConfirmed = true
        let profile = try LCCProfileBuilder.create(name: "Coverage crop test", aperture: nil, notes: "Generated test fixture", frames: [calibration],
            sensorLongEdge: 36,sensorShortEdge: 24)
        let profileURL = try LCCProfileStore().save(profile)
        defer { try? FileManager.default.removeItem(at: profileURL) }
        let engine = engine(), base = try PanoramaEngine().singlePhoto(source)
        // Move the photo beyond the calibration's measured footprint to require a real crop.
        let cropped = try await engine.correctPanorama(base,profileID: profile.id,offset: CGPoint(x: 8,y: 0),
            body: .alpa12Max,orientation: .degrees0,cropToCoverage: true,cancellation: .init(),progress: { _,_ in })
        let state = try XCTUnwrap(cropped.lccState), rect = try XCTUnwrap(state.cropRect)
        XCTAssertFalse(state.complete)
        XCTAssertEqual(rect,state.suggestedCropRect)
        XCTAssertGreaterThan(rect.width,0); XCTAssertLessThan(rect.width,base.size.width)
        XCTAssertEqual(cropped.outputSize,rect.size)
        XCTAssertEqual(try XCTUnwrap(cropped.preview).width,Int(rect.width))
        let uncropped = try await engine.setLCCCrop(cropped,enabled: false,cancellation: .init())
        XCTAssertNil(uncropped.lccState?.cropRect)
        XCTAssertEqual(uncropped.outputSize,base.size)
        XCTAssertEqual(uncropped.lccState?.offsetMM,state.offsetMM)
        XCTAssertEqual(uncropped.lccState?.profileID,state.profileID)
        let restored = try await engine.setLCCCrop(uncropped,enabled: true,cancellation: .init())
        XCTAssertEqual(restored.lccState?.cropRect,rect)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 2048
        let output = try await engine.export(photo: nil,edit: .neutral,plan: restored,manifest: nil,settings: settings,
            cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try PanoramaSource(url: output).size,rect.size)
        let manifest = try XCTUnwrap(PanoramaManifest.read(from: output))
        XCTAssertTrue(manifest.correctionApplied)
        XCTAssertEqual(manifest.crop.minX,rect.minX/base.size.width,accuracy: 1e-8)
        XCTAssertEqual(manifest.crop.width,rect.width/base.size.width,accuracy: 1e-8)
    }

    func testOptionalRealRAWWorkflow() async throws {
        let inputs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("ValidationInputs")
        let bundled = MobileSamples.boston
        let urls = (bundled.isEmpty ? ((try? FileManager.default.contentsOfDirectory(at: inputs,includingPropertiesForKeys: nil)) ?? []) : bundled)
            .filter { ["3fr","dng"].contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard urls.count >= 2 else { throw XCTSkip("No optional RAW fixtures supplied; use a local Boston sample build or Documents/ValidationInputs.") }
        let engine = engine()
        let photos = urls.enumerated().map { MobilePhoto(id: "real-\($0.offset)",name: $0.element.lastPathComponent,
            url: $0.element,rating: 0,width: 0,height: 0) }
        let preview = try await engine.frame(photos[0],edit: .neutral,hdr: true,edge: 1200)
        XCTAssertGreaterThan(preview.image.width,100)
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),
                                           progress: { text,_ in print("RAW ALIGN",text) })
        XCTAssertEqual(plan.sources.count,photos.count)
        _ = try await engine.profiles()
        let corrected = try await engine.correctPanorama(plan,profileID: LCCLensProfile.builtInID,offset: nil,
            body: .alpa12Max,orientation: .degrees0,cancellation: .init(),progress: { text,_ in print("RAW LCC",text) })
        XCTAssertNotNil(corrected.lccState)
        var settings = MobileExportSettings();settings.format = "dng";settings.longEdge = 6000
        let output = try await engine.export(photo: nil,edit: .neutral,plan: corrected,manifest: nil,settings: settings,
                                            cancellation: .init(),progress: { text,_ in print("RAW EXPORT",text) })
        XCTAssertTrue(try XCTUnwrap(PanoramaManifest.read(from: output)).correctionApplied)
        let validation = inputs.deletingLastPathComponent().appendingPathComponent("ValidationOutputs",isDirectory: true)
        try FileManager.default.createDirectory(at: validation,withIntermediateDirectories: true)
        let saved = validation.appendingPathComponent("Boston-6000.dng")
        try? FileManager.default.removeItem(at: saved)
        try FileManager.default.copyItem(at: output,to: saved)
        print("REAL ORIGINS",plan.origins,"gains",plan.gains,"MASK",plan.maskWidth,plan.maskHeight)
        let scene = try PanoramaEngine().renderComposite(corrected,outputLongEdge: 6000)
        let context = CIContext()
        try context.writePNGRepresentation(of: scene.applyingFilter("CIExposureAdjust",parameters: ["inputEV": -1]),to: validation.appendingPathComponent("Boston-before-DNG.png"),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let uncorrected = try PanoramaEngine().renderComposite(plan,outputLongEdge: 6000)
        try context.writePNGRepresentation(of: uncorrected.applyingFilter("CIExposureAdjust",parameters: ["inputEV": -1]),to: validation.appendingPathComponent("Boston-no-LCC.png"),format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let exportedPreview = try await engine.frame(MobilePhoto(id: "export",name: "export",url: output,rating: 0,width: 0,height: 0),edit: .neutral,hdr: false,edge: 6000)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(validation.appendingPathComponent("Boston-6000-preview.png") as CFURL,"public.png" as CFString,1,nil))
        CGImageDestinationAddImage(destination,exportedPreview.image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        print("REAL RAW SUCCESS",plan.size,output.lastPathComponent)
    }

    func testPerspectiveModeFitsWarpAndPreservesCaptureModel() async throws {
        let urls = try MobileSamples.create(in: folder.appendingPathComponent("perspective"))
        let input = try XCTUnwrap(CIImage(contentsOf: urls[1]))
        let warped = input.applyingFilter("CIPerspectiveTransform", parameters: [
            "inputTopLeft": CIVector(x: 0,y: 512), "inputTopRight": CIVector(x: 768,y: 498),
            "inputBottomLeft": CIVector(x: 12,y: 4), "inputBottomRight": CIVector(x: 756,y: 0)])
        let context = CIContext()
        let raster = try XCTUnwrap(context.createCGImage(warped, from: CGRect(x: 0,y: 0,width: 768,height: 512)))
        let output = folder.appendingPathComponent("perspective.tiff")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(output as CFURL,"public.tiff" as CFString,1,nil))
        CGImageDestinationAddImage(destination,raster,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photos = [urls[0],output].enumerated().map { MobilePhoto(id: "perspective-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 768,height: 512) }
        let plan = try await engine().analyze(photos,options: .init(),positions: [:],sensor: nil,
            registrationMode: .perspective,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(plan.registrationMode,.perspective)
        let warps = try XCTUnwrap(plan.warps)
        XCTAssertEqual(warps.count,2)
        XCTAssertGreaterThan(abs(warps[1].values[1]) + abs(warps[1].values[3]),0.001)
        let packet = try PanoramaManifest(plan: plan).encoded()
        let manifest = try JSONDecoder().decode(PanoramaManifest.self,from: packet)
        XCTAssertEqual(manifest.registrationMode,.perspective)
        XCTAssertEqual(manifest.projection,"projective")
        let profile = try LCCProfileStore().load(LCCLensProfile.builtInID)
        XCTAssertThrowsError(try LCCCorrectionEngine.postProcess(scene: plan.sources[0],manifest: manifest,profile: profile)) {
            XCTAssertTrue($0.localizedDescription.contains("before perspective stitching"))
        }
    }

    func testShiftDraggingUsesPhysicalScaleAndCameraTravel() {
        let travel = PanoramaCameraBody.alpa12Max.travel(at: .degrees0)
        let moved = MobileShiftGeometry.dragged(.zero, translation: CGSize(width: 20,height: -10), pointsPerMM: 2, travel: travel)
        XCTAssertEqual(moved.x, 10); XCTAssertEqual(moved.y, 5)
        let clamped = MobileShiftGeometry.dragged(moved, translation: CGSize(width: 1000,height: -1000), pointsPerMM: 2, travel: travel)
        XCTAssertEqual(clamped, CGPoint(x: 18,y: 25))
        let rotated = PanoramaCameraBody.alpa12STC.travel(at: .degrees90)
        let vertical = MobileShiftGeometry.dragged(.zero, translation: CGSize(width: 20,height: -20), pointsPerMM: 2, travel: rotated)
        XCTAssertEqual(vertical.x, 0); XCTAssertEqual(vertical.y, 10)
    }

    func testLargeLinearDNGHasContinuousTileBoundaries() throws {
        let width = 6000, height = 773
        let gradient = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0,y: 0), "inputPoint1": CIVector(x: CGFloat(width),y: CGFloat(height)),
            "inputColor0": CIColor(red: 0.2,green: 0.3,blue: 0.4),
            "inputColor1": CIColor(red: 0.6,green: 0.7,blue: 0.8)
        ])?.outputImage).cropped(to: CGRect(x: 0,y: 0,width: width,height: height))
        // Model the partial coverage seen at RAW/resampling joins in the real Boston panorama.
        // These lines deliberately do not follow the 256-pixel DNG tile lattice.
        let gray = CIImage(color: CIColor(red: 0.8,green: 0.8,blue: 0.8))
        var coverage = CIImage(color: .white).cropped(to: gradient.extent)
        for x in stride(from: 619,to: width,by: 619) {
            coverage = gray.cropped(to: CGRect(x: x,y: 0,width: 4,height: height)).composited(over: coverage)
        }
        coverage = gray.cropped(to: CGRect(x: 0,y: 301,width: width,height: 3)).composited(over: coverage)
        let image = gradient.applyingFilter("CIBlendWithMask",parameters: ["inputBackgroundImage": CIImage(color: .clear),"inputMaskImage": coverage])
            .cropped(to: gradient.extent)
        let context = CIContext(options: [.workingColorSpace: PanoramaEngine.linearSpace])
        let url = folder.appendingPathComponent("continuous-6000.dng")
        try LinearDNGWriter.write(image: image,context: context,to: url)
        let raw = try XCTUnwrap(CIRAWFilter(imageURL: url))
        raw.boostAmount = 0; raw.isGamutMappingEnabled = false; raw.sharpnessAmount = 0
        raw.isLensCorrectionEnabled = false
        let decoded = try XCTUnwrap(raw.outputImage)
        XCTAssertEqual(decoded.extent.size,CGSize(width: width,height: height))
        var values = [Float](repeating: 0,count: width * height * 4)
        context.render(decoded,toBitmap: &values,rowBytes: width * 16,bounds: decoded.extent,
            format: .RGBAf,colorSpace: PanoramaEngine.linearSpace)
        var minimum: Float = 1, maximumBoundaryJump: Float = 0
        for y in 4..<(height-4) { for x in 4..<(width-4) {
            let p = (y*width+x)*4
            minimum = min(minimum,values[p],values[p+1],values[p+2])
            for c in 0..<3 {
                maximumBoundaryJump = max(maximumBoundaryJump,abs(values[p+c]-values[p-4+c]),abs(values[p+c]-values[p-width*4+c]))
            }
        }}
        XCTAssertGreaterThan(minimum,0.025,"No dark grid inside a smooth image")
        XCTAssertLessThan(maximumBoundaryJump,0.015,"Lossless DNG tiles must join continuously")
    }

    func testHDRPreviewPreservesHighlightsAndDeclaresHeadroom() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("hdr"))
        let photo = MobilePhoto(id: "hdr",name: "HDR",url: urls[0],rating: 0,width: 768,height: 512)
        var edit = EditModel.neutral; edit.light.exposure = 3
        let hdr = try await engine.frame(photo,edit: edit,hdr: true,edge: 320)
        let sdr = try await engine.frame(photo,edit: edit,hdr: false,edge: 320)
        func maximum(_ cg: CGImage) -> Float {
            let image = CIImage(cgImage: cg), context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!])
            let maxImage = image.applyingFilter("CIAreaMaximum",parameters: ["inputExtent": CIVector(cgRect: image.extent)])
            var sample = [Float](repeating: 0,count: 4)
            context.render(maxImage,toBitmap: &sample,rowBytes: 16,bounds: CGRect(x: 0,y: 0,width: 1,height: 1),
                format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
            return max(sample[0],sample[1],sample[2])
        }
        XCTAssertGreaterThan(maximum(hdr.image),1.2)
        XCTAssertLessThanOrEqual(maximum(sdr.image),1.001)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        XCTAssertGreaterThan(hdr.image.contentHeadroom,1,"UIKit needs declared headroom for HDR presentation")
        await MainActor.run {
            print("SCREEN EDR",UIScreen.main.currentEDRHeadroom,UIScreen.main.potentialEDRHeadroom)
            let view = MobilePreviewSurface(); view.present(hdr.image,hdr: true)
            XCTAssertTrue((view.layer.contents as! CGImage) === hdr.image)
            if #available(iOS 26.0, *) { XCTAssertEqual(view.layer.preferredDynamicRange,.high) }
            else { XCTAssertTrue(view.layer.wantsExtendedDynamicRangeContent) }
            view.present(sdr.image,hdr: false)
            if #available(iOS 26.0, *) { XCTAssertEqual(view.layer.preferredDynamicRange,.standard) }
            else { XCTAssertFalse(view.layer.wantsExtendedDynamicRangeContent) }
        }
        var history = EditHistory(baseline: .neutral); history.commit(edit,label: "HDR",coalesce: false)
        _ = try await engine.importPhotos([photo.url],skipDuplicates: true,progress: { _,_ in })
        let importedPhotos = try await engine.photos()
        let imported = try XCTUnwrap(importedPhotos.first)
        try await engine.save(edit,history: history,id: imported.id)
        let thumb = try await engine.thumbnail(imported,hdr: true)
        let cached = try await self.engine().thumbnail(imported,hdr: true)
        XCTAssertEqual(cached.image.contentHeadroom,thumb.image.contentHeadroom)
        XCTAssertGreaterThan(maximum(cached.image),1.2,"Persisted thumbnails must keep HDR samples")
        XCTAssertEqual(cached.histogram,thumb.histogram)
        let cacheURLs = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Test.photonslibrary/MobilePreviews"),includingPropertiesForKeys: nil)
        XCTAssertTrue(cacheURLs.contains { $0.pathExtension == "pair" })
    }

    func testPanoramaToneUpdatesPreviewHistogramAndExport() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("tone"))
        let photos = urls.enumerated().map { MobilePhoto(id: "tone-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 0,height: 0) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,cancellation: .init(),progress: { _,_ in })
        let baseline = try await engine.frame(plan,hdr: true)
        let tone = PanoramaToneSettings(exposureEV: 2,highlightHeadroom: 2)
        let adjusted = try await engine.adjustPanoramaTone(plan,settings: tone)
        let hdr = try await engine.frame(adjusted,hdr: true), sdr = try await engine.frame(adjusted,hdr: false)
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),baseline.histogram?.binsDigest())
        XCTAssertNotEqual(hdr.histogram?.binsDigest(),sdr.histogram?.binsDigest())
        XCTAssertGreaterThan(hdr.image.contentHeadroom,1)
        XCTAssertLessThanOrEqual(hdr.image.contentHeadroom,2.01)
        XCTAssertEqual(adjusted.origins,plan.origins); XCTAssertEqual(adjusted.gains,plan.gains)
        var settings = MobileExportSettings(); settings.format = "dng"; settings.longEdge = 604
        let output = try await engine.export(photo: nil,edit: .neutral,plan: adjusted,manifest: nil,settings: settings,cancellation: .init(),progress: { _,_ in })
        XCTAssertEqual(try XCTUnwrap(PanoramaManifest.read(from: output)).tone,tone)
        let reset = try await engine.adjustPanoramaTone(adjusted,settings: .panoramaDefault)
        let resetFrame = try await engine.frame(reset,hdr: true)
        XCTAssertEqual(resetFrame.histogram?.binsDigest(),baseline.histogram?.binsDigest())
    }

    func testOptionalBostonSixFrameTone() async throws {
        let inputs = FileManager.default.urls(for: .documentDirectory,in: .userDomainMask)[0].appendingPathComponent("ValidationInputs/628-633")
        let urls = (628...633).map { inputs.appendingPathComponent(String(format: "B%07d.3FR",$0)) }
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { throw XCTSkip("Optional local six-frame Boston fixture") }
        let engine = engine(), photos = urls.enumerated().map { MobilePhoto(id: "six-\($0.offset)",name: $0.element.lastPathComponent,url: $0.element,rating: 0,width: 0,height: 0) }
        let plan = try await engine.analyze(photos,options: .init(),positions: [:],sensor: nil,tone: .init(),cancellation: .init(),progress: { text,_ in print("BOSTON SIX",text) })
        let before = try await engine.frame(plan,hdr: true)
        let tone = PanoramaToneSettings(exposureEV: 1,highlightHeadroom: 2)
        let adjusted = try await engine.adjustPanoramaTone(plan,settings: tone)
        let after = try await engine.frame(adjusted,hdr: true)
        XCTAssertEqual(plan.sources.count,6); XCTAssertEqual(adjusted.origins,plan.origins)
        XCTAssertNotEqual(before.histogram?.binsDigest(),after.histogram?.binsDigest())
        XCTAssertGreaterThan(after.image.contentHeadroom,1); XCTAssertLessThan(after.image.contentHeadroom,2.01)
        let outputs = inputs.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ValidationOutputs")
        try FileManager.default.createDirectory(at: outputs,withIntermediateDirectories: true)
        for (name,frame) in [("628-before",before),("628-brighter",after)] {
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(outputs.appendingPathComponent("\(name).png") as CFURL,"public.png" as CFString,1,nil))
            CGImageDestinationAddImage(destination,frame.image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        print("BOSTON SIX TONE",plan.size,before.image.contentHeadroom,after.image.contentHeadroom)
    }

    func testCancellationDoesNotCreateOutput() async throws {
        let engine = engine(), urls = try MobileSamples.create(in: folder.appendingPathComponent("samples"))
        _ = try await engine.importPhotos(urls, skipDuplicates: true, progress: { _,_ in })
        let photos = try await engine.photos(), cancellation = PanoramaCancellation(); cancellation.cancel()
        do {
            _ = try await engine.analyze(photos, options: .init(), positions: [:], sensor: nil,
                                         cancellation: cancellation, progress: { _,_ in })
            XCTFail("Cancelled alignment should throw")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Exports").path)) }
    }

    private func makeFlat(name: String, exposure: Float) throws -> URL {
        let width = 320, height = 240
        let neutral: [Double] = [0.4,1,0.65]
        let pattern = [0,1,3,2], gains: [Float] = [0.4,1,0.65,1]
        var pixels = [Float](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width {
            let dx = Float(x) / Float(width-1) - 0.5, dy = Float(y) / Float(height-1) - 0.5
            let falloff = Float(0.6) * exp(-1.6 * (dx*dx + dy*dy)) * exposure
            pixels[y*width+x] = falloff * gains[pattern[(y%2)*2+x%2]]
        } }
        let mosaic = CameraMosaic(width: width,height: height,samples: pixels,pattern: pattern,
            neutral: neutral,matrix: [0.6468,-0.1899,-0.0545,-0.4526,1.2267,0.2542,-0.0388,0.1276,0.6096])
        let data = mosaic.dng().data
        let url = folder.appendingPathComponent(name)
        try data.write(to: url); return url
    }
}
