//
//  CLIProtocol.swift
//  hdrmerge-swift
//
//  The machine-facing side of the command line: stable JSON envelopes, stable
//  exit codes, NDJSON progress events. Hosts (e.g. Photons) drive this tool as a
//  child process — see PROTOCOL.md. Nothing here links into the host, which is
//  what keeps the GPLv3 boundary a plain aggregate.
//

import Foundation
import HDRMergeCore

// MARK: - Envelope

enum ExitCode: Int32 {
    case ok = 0
    case usage = 2
    case badInput = 3          // file unreadable / not a CFA DNG
    case incompatible = 4      // frames cannot be merged together
    case writeFailed = 5
    case internalError = 6
}

/// One JSON object per invocation on stdout. Never mixed with logs: those go to
/// stderr, so a host can parse stdout blindly.
struct Response {
    var ok: Bool
    var command: String
    var payload: [String: Any] = [:]
    var warnings: [String] = []
    var error: (code: String, message: String)?

    func emit() {
        var obj: [String: Any] = ["ok": ok, "command": command]
        for (k, v) in payload { obj[k] = v }
        if !warnings.isEmpty { obj["warnings"] = warnings }
        if let e = error { obj["error"] = ["code": e.code, "message": e.message] }
        obj["tool"] = ["name": "hdrmerge-swift", "protocol": 1, "version": ProtocolInfo.version]
        let data = (try? JSONSerialization.data(withJSONObject: obj,
                                                options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{\"ok\":false}".utf8)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

enum ProtocolInfo {
    static let version = "0.2.0"
    /// Machine-readable description of this protocol, so a host can negotiate.
    static let features: [String] = [
        "inspect", "merge", "decode-pgm", "ndjson-progress", "atomic-write",
        "headroom", "metadata-passthrough",
    ]
}

// MARK: - Progress

/// `{"event":"progress","phase":"decode","index":1,"total":3,"file":"A.dng"}`
/// written to stderr, one object per line, only with `--progress`.
struct ProgressReporter {
    let enabled: Bool
    private let lock = NSLock()

    init(enabled: Bool) { self.enabled = enabled }

    func event(_ phase: String, _ fields: [String: Any] = [:]) {
        guard enabled else { return }
        var obj: [String: Any] = ["event": "progress", "phase": phase]
        for (k, v) in fields { obj[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        lock.lock()
        FileHandle.standardError.write(data)
        FileHandle.standardError.write(Data("\n".utf8))
        lock.unlock()
    }

    /// Human-readable diagnostics; prefixed so a host can forward them to a log.
    func log(_ message: String) {
        FileHandle.standardError.write(Data(("hdrmerge-swift: " + message + "\n").utf8))
    }
}

// MARK: - Errors

/// Errors carry a stable `code` so the host can map them to real UI messages
/// instead of string-matching prose.
struct CLIError: Error {
    let code: String
    let message: String
    let exit: ExitCode

    init(_ code: String, _ message: String, exit: ExitCode) {
        self.code = code
        self.message = message
        self.exit = exit
    }

    static func wrap(_ error: Error) -> CLIError {
        switch error {
        case let e as DNGError:
            let code: String
            switch e {
            case .noCFAImage: code = "not_a_cfa_dng"
            case .linearRawUnsupported: code = "linear_dng"
            case .unsupportedCompression: code = "unsupported_compression"
            case .inconsistentGeometry: code = "bad_geometry"
            }
            return CLIError(code, e.description, exit: .badInput)
        case let e as MergeError:
            let code: String
            switch e {
            case .noFrames: code = "no_frames"
            case .geometryMismatch: code = "geometry_mismatch"
            case .nothingToMerge: code = "no_overlap"
            }
            return CLIError(code, e.description, exit: .incompatible)
        case let e as TIFFError:
            return CLIError("not_tiff", e.description, exit: .badInput)
        case let e as LJpegError:
            return CLIError("bad_lossless_jpeg", e.description, exit: .badInput)
        case let e as CocoaError:
            return CLIError("io_error", "\(e)", exit: .badInput)
        default:
            return CLIError("internal", "\(error)", exit: .internalError)
        }
    }
}

// MARK: - Small helpers

extension RawFrame {
    var jsonSummary: [String: Any] {
        [
            "path": url.path,
            "fileName": url.lastPathComponent,
            "make": make,
            "model": model,
            "rawWidth": fullWidth,
            "rawHeight": fullHeight,
            "width": activeWidth,
            "height": activeHeight,
            "cfaPattern": cfaPattern.map { Int($0) },
            "cfaRows": cfaRows,
            "cfaCols": cfaCols,
            "blackLevel": blackLevel,
            "whiteLevel": whiteLevel,
            "exposureTime": exposureTime,
            "iso": iso,
            "asShotNeutral": asShotNeutral,
        ]
    }
}

/// Write via a sibling temporary file and `rename`, so a host never sees a
/// half-written DNG if the process is killed.
func atomicWrite(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
    do {
        try data.write(to: tmp)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tmp, to: url)
    } catch {
        try? FileManager.default.removeItem(at: tmp)
        throw error
    }
}
