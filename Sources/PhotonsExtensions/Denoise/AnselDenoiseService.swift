//
//  AnselDenoiseService.swift
//
//  Image-level driver: write the mosaic to a file, hand it to `ansel-denoise-swift` (GPLv3,
//  separate process), read the result back. MIT — nothing here is derived from the upstream
//  network code.
//
//  This is deliberately thin. Everything that could be described as *how the image is processed*
//  — whether it goes through in one pass, how many pieces it must be cut into to fit in memory,
//  where the cuts fall, how they are feathered — lives in the GPL tool, because all of it is a
//  consequence of that implementation's own memory profile and edge behaviour. A host that
//  reimplemented that arithmetic would have to track a number that changes whenever those kernels
//  change.
//
//  What stays here is what belongs to the host: the file plumbing and the translation of the
//  tool's report into something the caller can act on.
//

import Foundation

/// Result of a denoise run: the mosaic plus what the run cost.
public struct AnselDenoiseOutcome: Sendable {
    public let mosaic: [Float]        // width × height, normalized like the input
    public let width: Int
    public let height: Int
    /// Pieces the tool used. 1 means a single pass, i.e. no seams anywhere in the frame.
    public let pieces: Int
    public let columns: Int
    public let rows: Int
    /// Internal cuts that had to be feathered. Zero is the goal.
    public let seams: Int
    public let seconds: Double
    public let backend: String
    /// Bytes the largest single forward pass needed.
    public let peakBytes: Int
}

public enum AnselDenoiseServiceError: Error, CustomStringConvertible {
    case emptyInput
    case badGeometry(String)
    case temporaryFileFailed(String)

    public var description: String {
        switch self {
        case .emptyInput:               return "empty mosaic"
        case .badGeometry(let m):       return "bad geometry: \(m)"
        case .temporaryFileFailed(let m): return "temporary file failed: \(m)"
        }
    }
}

public struct AnselDenoiseService: Sendable {
    public let client: AnselDenoiseClient
    public let modelURL: URL

    public init(client: AnselDenoiseClient, modelURL: URL) {
        self.client = client
        self.modelURL = modelURL
    }

    /// Denoise one mosaic.
    ///
    /// - Parameters:
    ///   - mosaic: normalized values (black subtracted, divided by white level), row-major.
    ///   - options: noise coefficients, CFA, sigma calibration, strength.
    /// - Returns: the denoised mosaic at the same size.
    public func denoise(mosaic: [Float],
                        width: Int,
                        height: Int,
                        options: AnselDenoiseOptions) throws -> AnselDenoiseOutcome {
        guard width > 0, height > 0, mosaic.count == width * height else {
            throw AnselDenoiseServiceError.emptyInput
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ansel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = directory.appendingPathComponent("mosaic.f32")
        let output = directory.appendingPathComponent("denoised.f32")

        do {
            try mosaic.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: input)
        } catch {
            throw AnselDenoiseServiceError.temporaryFileFailed("write \(input.path): \(error)")
        }

        let report = try client.denoiseImage(model: modelURL, input: input,
                                             width: width, height: height,
                                             output: output, options: options)

        let data = try Data(contentsOf: output, options: .mappedIfSafe)
        let expected = width * height * MemoryLayout<Float>.size
        guard data.count == expected else {
            throw AnselDenoiseServiceError.badGeometry(
                "tool returned \(data.count) bytes, expected \(expected) for \(width)×\(height)")
        }
        var result = [Float](repeating: 0, count: width * height)
        result.withUnsafeMutableBytes { data.copyBytes(to: $0) }

        return AnselDenoiseOutcome(mosaic: result, width: width, height: height,
                                   pieces: report.pieces,
                                   columns: report.columns, rows: report.rows,
                                   seams: report.seams,
                                   seconds: report.milliseconds / 1000,
                                   backend: report.backend,
                                   peakBytes: report.peakBytes)
    }
}
