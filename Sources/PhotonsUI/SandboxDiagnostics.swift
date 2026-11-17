import Foundation
import CoreImage
import ImageIO
import PhotonsCore
import PhotonsExport
import PhotonsPanorama
import PhotonsJobs
import PhotonsCatalog
import PhotonsExtensions
import PhotonsFileAccess

/// Explicit command-line diagnostic for the signed app. Uses synthetic pixels in its own
/// container, never a user's library. External PowerBox grants still require an interactive test.
public enum SandboxDiagnostics {
    public static func run() -> Int32 {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PhotonsSandboxCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            guard SandboxEnvironment.isSandboxed else { throw Failure("App Sandbox is not enabled") }
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let bookmark = try FileAccessStore.bookmark(for: scratch)
            let restored = try FileAccessStore.resolve(bookmark).access
            defer { withExtendedLifetime(restored) {} }
            let input = restored.url.appendingPathComponent("input.f32")
            let output = restored.url.appendingPathComponent("output.f32")
            let samples = [Float](repeating: 0.25, count: 64 * 64)
            try samples.withUnsafeBytes { try Data($0).write(to: input) }
            let hdr = try HDRMergeClient(resolvingExplicit: nil)
            let denoise = try AnselDenoiseClient(resolvingExplicit: nil)
            let hdrVersion = try hdr.protocolVersion()
            let denoiseVersion = try denoise.protocolVersion()
            let gpu = try denoise.gpuName()
            guard let model = AnselDenoiseLocation().resolvedModel() else { throw Failure("Bundled denoise model is missing") }
            var options = AnselDenoiseOptions()
            options.noiseA = [0, 0, 0]; options.noiseB = [0.0001, 0.0001, 0.0001]; options.useGPU = true
            _ = try denoise.denoiseImage(model: model, input: input, width: 64, height: 64, output: output, options: options)
            let result = try Data(contentsOf: output)
            guard result.count == samples.count * MemoryLayout<Float>.size else { throw Failure("Denoise output size mismatch") }
            let panorama = try checkPanorama(in: scratch)
            let report: [String: Any] = ["sandbox": true, "bookmarkRoundTrip": true,
                "hdrHelperProtocol": hdrVersion, "denoiseHelperProtocol": denoiseVersion,
                "gpu": gpu ?? "unavailable", "denoiseOutputBytes": result.count,
                "panorama": panorama,
                "externalFolderAuthorization": "requires interactive file-panel verification"]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self)); return 0
        } catch {
            fputs("sandbox-check: \(error.localizedDescription)\n", stderr); return 1
        }
    }

    private static func checkPanorama(in folder:URL) throws -> [String:Any] {
        let sourceURL=folder.appendingPathComponent("B001.dng")
        let values:[Float]=[3,0.3,0.1,1]
        let image=CIImage(bitmapData:values.withUnsafeBytes {Data($0)},bytesPerRow:16,size:CGSize(width:1,height:1),format:.RGBAf,colorSpace:PanoramaEngine.linearSpace)
            .clampedToExtent().cropped(to:CGRect(x:0,y:0,width:640,height:320))
        try LinearDNGWriter.write(image:image,context:CIContext(),to:sourceURL)
        let source=try PanoramaSource(url:sourceURL),engine=PanoramaEngine()
        let plan=try engine.singlePhoto(source),manifest=PanoramaManifest(plan:plan)
        var preset=ExportSheetModel.defaultPreset
        preset.destination = .sourceFolder;preset.subfolder="HDR"
        let job=PanoramaJob(snapshot:try PanoramaSnapshot(plan:plan),manifest:manifest,preset:preset,linearDNG:false,
            outputDirectory:folder,bookmarks:[try folder.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)])
        let request=folder.appendingPathComponent("panorama.json")
        try JSONEncoder().encode(job).write(to:request)
        let process=Process(),pipe=Pipe()
        process.executableURL=Bundle.main.resourceURL!.appendingPathComponent("bin/photons-panorama-worker")
        process.arguments=[request.path];process.standardOutput=pipe
        try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        let events=data.split(separator:10).compactMap {try? JSONDecoder().decode(PanoramaWorkerEvent.self,from:Data($0))}
        guard process.terminationStatus==0,let output=events.last?.result else {throw Failure("Panorama worker failed: \(String(decoding:data,as:UTF8.self))")}
        guard try PanoramaManifest.read(from:output) != nil else {throw Failure("Panorama metadata missing")}
        let catalog=try Catalog.create(at:folder.appendingPathComponent("test.photonslibrary"))
        let imported=try ImportService(catalog:catalog).run(sources:[output],options:.init(mode:.reference))
        guard imported.failed==0,imported.addedAssetIDs.count==1 else {throw Failure("Panorama import failed")}
        return ["workerSucceeded":true,"metadataRoundTrip":true,"imported":imported.addedAssetIDs.count,
                "filename":output.lastPathComponent,"width":source.size.width,"height":source.size.height]
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
