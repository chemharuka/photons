//
//  HDRMergeClient.swift
//
//  Photons-side client for `hdrmerge-swift` (GPLv3). Drop this file into
//  PhotonsCore — it is MIT, like the rest of Photons, because it only *spawns*
//  the GPL binary as a child process and speaks JSON over pipes. Nothing is
//  linked: see LICENSE-SCOPE.md in the hdrmerge-swift repo.
//
//  Requires macOS 13+. No third-party dependencies.
//

import Foundation

// MARK: - Public model

/// Options mirror the CLI 1:1 so the host never has to build argument strings.
public struct HDRMergeOptions: Sendable, Equatable {
    /// 16 = integer DNG (readable by ImageIO / Preview), 32 = float DNG.
    public var bits: Int = 16
    /// Container top = headroom × input white level. `4` with `bits: 16` keeps the
    /// input scale bit-exact and leaves +2 stops of highlight room.
    public var headroom: Double = 1
    public var featherRadius: Int = 3
    /// Override the detected saturation level.
    public var whiteLevel: Int?
    /// Take EXIF/DNG metadata from this frame instead of the least exposed one.
    public var metadataFrom: URL?

    public init() {}
}

public struct HDRMergeResult: Sendable, Equatable {
    public let output: URL
    public let bytes: Int
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let bits: Int
    public let headroom: Double
    public let whiteLevel: Int
    public let blackLevel: Double
    public let cfaPattern: [Int]
    /// Placement of each input frame inside the merged canvas, in input order.
    public let offsets: [Offset]
    public let metadataFrom: URL
    public let report: [String]

    public struct Offset: Sendable, Equatable {
        public let x: Int
        public let y: Int
    }
}

public struct HDRMergeFrameInfo: Sendable, Equatable {
    public let url: URL
    public let make: String
    public let model: String
    public let width: Int
    public let height: Int
    public let cfaPattern: [Int]
    public let blackLevel: [Double]
    public let whiteLevel: Int
    public let exposureTime: Double
    public let iso: Double
}

/// Every failure carries the tool's stable `error.code`, so the UI can branch
/// without string-matching prose.
public struct HDRMergeFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: String
    public let message: String
    public let exitCode: Int32?

    public init(code: String, message: String, exitCode: Int32?) {
        self.code = code
        self.message = message
        self.exitCode = exitCode
    }

    public var description: String { "\(code): \(message)" }

    /// Human-facing hint for the codes we know about.
    public var kind: Kind {
        switch code {
        case "linear_dng": return .linearDNG
        case "not_a_cfa_dng", "not_tiff": return .notRaw
        case "unsupported_compression": return .unsupportedFormat
        case "geometry_mismatch", "no_overlap", "no_frames": return .incompatibleFrames
        case "io_error": return .fileUnreadable
        case "write_failed": return .cannotWrite
        case "tool_missing": return .toolMissing
        case "bad_response", "cancelled": return .toolFailed
        default: return .other
        }
    }

    public enum Kind: Sendable {
        case linearDNG, notRaw, unsupportedFormat, incompatibleFrames
        case fileUnreadable, cannotWrite, toolMissing, toolFailed, other
    }
}

public enum HDRMergeProgress: Sendable, Equatable {
    case decoding(index: Int, total: Int, file: URL)
    case merging(frames: Int)
    case encoding(bits: Int)
    case done(bytes: Int)
}

// MARK: - Client

/// Locates and drives the `hdrmerge-swift` executable.
///
/// Resolution order:
///   1. explicit `executableURL`
///   2. `$HDRMERGE_SWIFT` (dev override)
///   3. `Bundle.main/Contents/Resources/bin/hdrmerge-swift` (shipped inside the app)
///   4. `/opt/homebrew/bin/hdrmerge-swift`, `/usr/local/bin/hdrmerge-swift` (dev installs)
public struct HDRMergeClient: Sendable {
    public let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    public init(resolvingExplicit explicit: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                bundle: Bundle = .main) throws {
        if let explicit {
            self.executableURL = explicit
            return
        }
        if let env = environment["HDRMERGE_SWIFT"], FileManager.default.isExecutableFile(atPath: env) {
            self.executableURL = URL(fileURLWithPath: env)
            return
        }
        var candidates: [URL] = []
        if let res = bundle.resourceURL {
            candidates.append(res.appendingPathComponent("bin/hdrmerge-swift"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/hdrmerge-swift"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/hdrmerge-swift"))
        for c in candidates where FileManager.default.isExecutableFile(atPath: c.path) {
            self.executableURL = c
            return
        }
        throw HDRMergeFailure(code: "tool_missing",
                             message: "hdrmerge-swift not found (looked in app resources and /usr/local/bin)",
                             exitCode: nil)
    }

    /// `capabilities --json` — call once per launch to confirm the protocol version.
    public func protocolVersion() throws -> Int {
        let response = try runJSON(arguments: ["capabilities", "--json"])
        guard let tool = response["tool"] as? [String: Any],
              let protocolVersion = tool["protocol"] as? Int else {
            throw HDRMergeFailure(code: "bad_response",
                                 message: "capabilities did not report tool.protocol",
                                 exitCode: 0)
        }
        return protocolVersion
    }

    /// Pre-flight: geometry, CFA, black/white levels without merging.
    public func inspect(_ urls: [URL]) throws -> [HDRMergeFrameInfo] {
        guard !urls.isEmpty else { return [] }
        let response = try runJSON(arguments: ["inspect", "--json"] + urls.map(\.path))
        guard let frames = response["frames"] as? [[String: Any]] else {
            throw HDRMergeFailure(code: "bad_response", message: "inspect returned no frames", exitCode: 0)
        }
        return frames.compactMap { f in
            guard let path = f["path"] as? String else { return nil }
            return HDRMergeFrameInfo(
                url: URL(fileURLWithPath: path),
                make: f["make"] as? String ?? "",
                model: f["model"] as? String ?? "",
                width: f["width"] as? Int ?? 0,
                height: f["height"] as? Int ?? 0,
                cfaPattern: f["cfaPattern"] as? [Int] ?? [],
                blackLevel: f["blackLevel"] as? [Double] ?? [],
                whiteLevel: f["whiteLevel"] as? Int ?? 0,
                exposureTime: f["exposureTime"] as? Double ?? 0,
                iso: f["iso"] as? Double ?? 0)
        }
    }

    /// Merge `urls` into a new CFA DNG at `output`.
    ///
    /// Blocking; call it off the main actor. `progress` is invoked on an arbitrary
    /// queue, in order. `isCancelled` is polled between frames by killing the child,
    /// which leaves no partial output (the tool writes atomically).
    @discardableResult
    public func merge(_ urls: [URL],
                      to output: URL,
                      options: HDRMergeOptions = HDRMergeOptions(),
                      progress: (@Sendable (HDRMergeProgress) -> Void)? = nil,
                      isCancelled: (@Sendable () -> Bool)? = nil) throws -> HDRMergeResult {
        guard !urls.isEmpty else {
            throw HDRMergeFailure(code: "no_frames", message: "no input frames", exitCode: 4)
        }
        var args = ["merge", "--json", "--progress", "-o", output.path,
                    "-b", String(options.bits),
                    "--headroom", String(options.headroom),
                    "--feather", String(options.featherRadius)]
        if let white = options.whiteLevel { args += ["--white", String(white)] }
        if let meta = options.metadataFrom { args += ["--metadata-from", meta.path] }
        args.append("--")
        args += urls.map(\.path)

        let response = try runJSON(arguments: args, progress: progress, isCancelled: isCancelled)
        guard let out = response["output"] as? String,
              let width = response["width"] as? Int,
              let height = response["height"] as? Int else {
            throw HDRMergeFailure(code: "bad_response",
                                 message: "merge returned no output/size", exitCode: 0)
        }
        let offsets = (response["offsets"] as? [[String: Int]] ?? []).map {
            HDRMergeResult.Offset(x: $0["x"] ?? 0, y: $0["y"] ?? 0)
        }
        return HDRMergeResult(
            output: URL(fileURLWithPath: out),
            bytes: response["bytes"] as? Int ?? 0,
            width: width,
            height: height,
            frameCount: response["frames"] as? Int ?? urls.count,
            bits: response["bits"] as? Int ?? options.bits,
            headroom: response["headroom"] as? Double ?? options.headroom,
            whiteLevel: response["whiteLevel"] as? Int ?? 0,
            blackLevel: response["blackLevel"] as? Double ?? 0,
            cfaPattern: response["cfaPattern"] as? [Int] ?? [],
            offsets: offsets,
            metadataFrom: URL(fileURLWithPath: response["metadataFrom"] as? String ?? ""),
            report: response["report"] as? [String] ?? [])
    }

    // MARK: - process plumbing

    private func runJSON(arguments: [String],
                         progress: (@Sendable (HDRMergeProgress) -> Void)? = nil,
                         isCancelled: (@Sendable () -> Bool)? = nil) throws -> [String: Any] {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        // The tool must never inherit a controlling terminal or prompt.
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        var stderrTail = Data()
        let errLock = NSLock()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            errLock.lock()
            stderrTail.append(chunk)
            if stderrTail.count > 64 * 1024 {
                stderrTail.removeFirst(stderrTail.count - 64 * 1024)
            }
            errLock.unlock()
            if let progress {
                for line in chunk.split(separator: 0x0A) {
                    emitProgress(Data(line), to: progress)
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw HDRMergeFailure(code: "tool_missing",
                                 message: "cannot launch \(executableURL.path): \(error)",
                                 exitCode: nil)
        }

        // Cancellation: poll cheaply, terminate the child if asked to.
        let cancelQueue = DispatchQueue(label: "hdrmerge.cancel")
        var cancelled = false
        if let isCancelled {
            cancelQueue.async {
                while process.isRunning {
                    if isCancelled() {
                        cancelled = true
                        process.terminate()
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil

        if cancelled {
            throw HDRMergeFailure(code: "cancelled", message: "merge cancelled", exitCode: nil)
        }

        let exit = process.terminationStatus
        guard let obj = try? JSONSerialization.jsonObject(with: outData) as? [String: Any] else {
            errLock.lock()
            let tail = String(decoding: stderrTail, as: UTF8.self)
            errLock.unlock()
            throw HDRMergeFailure(code: "bad_response",
                                 message: "unparseable output (exit \(exit)): \(tail.suffix(500))",
                                 exitCode: exit)
        }
        if (obj["ok"] as? Bool) != true {
            let error = obj["error"] as? [String: Any] ?? [:]
            throw HDRMergeFailure(code: error["code"] as? String ?? "internal",
                                 message: error["message"] as? String ?? "unknown failure",
                                 exitCode: exit)
        }
        return obj
    }

    private func emitProgress(_ line: Data, to sink: @Sendable (HDRMergeProgress) -> Void) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["event"] as? String == "progress",
              let phase = obj["phase"] as? String else { return }
        switch phase {
        case "decode":
            sink(.decoding(index: obj["index"] as? Int ?? 0,
                           total: obj["total"] as? Int ?? 0,
                           file: URL(fileURLWithPath: obj["file"] as? String ?? "")))
        case "merge":
            sink(.merging(frames: obj["frames"] as? Int ?? 0))
        case "encode":
            sink(.encoding(bits: obj["bits"] as? Int ?? 16))
        case "done":
            sink(.done(bytes: obj["bytes"] as? Int ?? 0))
        default:
            break
        }
    }
}
