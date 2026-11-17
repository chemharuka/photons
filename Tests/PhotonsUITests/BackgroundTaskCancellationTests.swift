import XCTest
import CoreImage
import PhotonsCore
import PhotonsExport
import PhotonsPanorama
@testable import PhotonsUI

@MainActor final class BackgroundTaskCancellationTests:XCTestCase {
    func testCancelTerminatedWorkerCleansItsPartialAndPreservesExistingOutput() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:folder)}
        let sourceURL=folder.appendingPathComponent("input.tiff")
        let image=CIImage(color:CIColor(red:0.3,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:32,height:24))
        try CIContext().writeTIFFRepresentation(of:image,to:sourceURL,format:.RGBA16,colorSpace:PanoramaEngine.linearSpace)
        let plan=try PanoramaEngine().singlePhoto(PanoramaSource(url:sourceURL))
        let existing=folder.appendingPathComponent("input_pano.heic"),bytes=Data("existing user's export".utf8)
        try bytes.write(to:existing)
        let worker=folder.appendingPathComponent("test-worker")
        let script="""
        #!/usr/bin/python3
        import json,sys,os,time
        job=json.load(open(sys.argv[1]))
        from urllib.parse import urlparse,unquote
        stage=unquote(urlparse(job['stagingDirectory']).path)
        os.makedirs(stage)
        open(os.path.join(stage,'partial.heic'),'wb').write(b'incomplete')
        print(json.dumps({'message':'encoding','fraction':0.5,'finished':False}),flush=True)
        while True: time.sleep(0.1)
        """
        try script.write(to:worker,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:worker.path)
        let queue=BackgroundTasks(worker:worker)
        try queue.submit(plan:plan,manifest:PanoramaManifest(plan:plan),preset:ExportSheetModel.defaultPreset,dng:false,directory:folder) {_,_ in XCTFail("Cancelled output must never be imported")}
        let task=try XCTUnwrap(queue.tasks.first)
        let stage=folder.appendingPathComponent(".photons-job-\(task.id.uuidString)")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath:stage.appendingPathComponent("partial.heic").path) {try await Task.sleep(nanoseconds:25_000_000)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.path))
        task.cancel()
        for _ in 0..<200 where task.active {try await Task.sleep(nanoseconds:25_000_000)}
        XCTAssertEqual(task.state,.cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath:stage.path))
        XCTAssertEqual(try Data(contentsOf:existing),bytes)
    }
}
