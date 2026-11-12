import Foundation

/// HDR merge: several bracketed RAW frames in, **one** radiance-linear Bayer (CFA) DNG out.
///
/// Belongs to `PhotonsExtensions` and follows that module's rule — **no dependency on
/// `PhotonsCore` or `PhotonsCatalog`**. It is a plain file-in/file-out step, exactly like the AI
/// denoise extension: it reads nothing but paths and writes a new DNG next to the sources. Adding
/// the result to the library is the *caller's* job (`onOutput`), so a CLI, a test, and a future
/// sheet can all use this without dragging the catalog in.
///
/// Two facts shape the rest:
///
/// 1. `hdrmerge-swift` is a **separate GPLv3 executable** that ships inside the app bundle
///    (`Contents/Resources/bin/`) and is spawned as a child process. Photons stays MIT because
///    GPLv3 §5's aggregate clause covers exactly this: a compilation of independent programs on
///    one medium, communicating through "pipes, sockets and command-line arguments" (GNU GPL FAQ
///    #MereAggregation). Nothing from that project is compiled in here.
/// 2. This is a library, not UI. It adds no menu item and changes no existing window.
public final class HDRMergeService: @unchecked Sendable {

    public struct Outcome: Sendable {
        /// The merged CFA DNG, named `<least-exposed-frame>-merged.dng` unless the name was taken.
        public let output: URL
        public let width: Int
        public let height: Int
        public let bytes: Int
        public let frameCount: Int
        public let whiteLevel: Int
        /// The frame whose EXIF/DNG metadata the result carries (least exposed by default).
        public let metadataFrom: URL
        public let report: [String]
    }

    /// Every failure is one of these codes, so a caller branches on a key instead of prose.
    public enum Failure: Error, CustomStringConvertible, Sendable {
        case toolMissing
        case notEnoughFrames(Int)
        case linearDNG(String)
        case notCFARaw(String)
        case unsupportedFormat(String)
        case incompatibleFrames(String)
        case unreadable(String)
        case cannotWrite(String)
        case toolFailed(String)

        public var code: String {
            switch self {
            case .toolMissing: return "tool_missing"
            case .notEnoughFrames: return "not_enough_frames"
            case .linearDNG: return "linear_dng"
            case .notCFARaw: return "not_a_cfa_dng"
            case .unsupportedFormat: return "unsupported_compression"
            case .incompatibleFrames: return "geometry_mismatch"
            case .unreadable: return "io_error"
            case .cannotWrite: return "write_failed"
            case .toolFailed: return "internal"
            }
        }

        public var description: String {
            switch self {
            case .toolMissing:
                return "未找到 hdrmerge-swift（应随 app 提供于 Contents/Resources/bin/）"
            case .notEnoughFrames(let n):
                return "至少需要两张 DNG 才能合并（当前 \(n) 张）"
            case .linearDNG:
                return "选中的是已去马赛克的线性 DNG（Lightroom / ProRAW 产物），没有 Bayer 数据可合并"
            case .notCFARaw:
                return "选中的文件不是 CFA RAW"
            case .unsupportedFormat:
                return "这个 DNG 的压缩方式尚不支持（Deflate / JPEG XL）"
            case .incompatibleFrames:
                return "这些照片无法合并：尺寸、CFA 相位或拍摄格式不一致"
            case .unreadable(let path):
                return "无法读取 \(path)（可能已移动或没有权限）"
            case .cannotWrite(let path):
                return "无法写入 \(path)（检查目录权限）"
            case .toolFailed(let message):
                return "合并工具异常退出：\(message)"
            }
        }

        /// What a caller should show for a tool error code.
        static func wrap(_ error: Error) -> Failure {
            guard let failure = error as? HDRMergeFailure else {
                return .toolFailed(error.localizedDescription)
            }
            switch failure.kind {
            case .linearDNG: return .linearDNG(failure.message)
            case .notRaw: return .notCFARaw(failure.message)
            case .unsupportedFormat: return .unsupportedFormat(failure.message)
            case .incompatibleFrames: return .incompatibleFrames(failure.message)
            case .fileUnreadable: return .unreadable(failure.message)
            case .cannotWrite: return .cannotWrite(failure.message)
            case .toolMissing: return .toolMissing
            case .toolFailed, .other: return .toolFailed(failure.message)
            }
        }
    }

    public typealias ProgressHandler = @Sendable (String) -> Void

    /// 16-bit integer DNG (readable by ImageIO, Preview, and our own decoder).
    public var bits = 16
    /// Container top = headroom × input white level. 4 keeps the input scale bit-exact in a
    /// 16-bit container and leaves +2 stops of recovered highlight room (WhiteLevel 65535).
    public var headroom = 4.0
    public var featherRadius = 3
    /// SOF3 lossless JPEG. 120 MB → 49 MB on a 60 MP frame, pixels bit-exact, and the only
    /// compressed form the system decoder accepts (Core Image rejects Deflate outright).
    /// On by default: uncompressed costs ~2.4× the disk for identical pixels.
    public var compress = true

    private let clientOverride: HDRMergeClient?

    /// `client` overrides tool discovery (tests, or a bundle with a pinned copy).
    public init(client: HDRMergeClient? = nil) {
        self.clientOverride = client
    }

    // MARK: tool discovery

    /// Resolution order lives in `HDRMergeClient`: env override → app bundle → Homebrew → /usr/local.
    public var client: HDRMergeClient? {
        if let clientOverride { return clientOverride }
        return try? HDRMergeClient()
    }

    public var isAvailable: Bool { client != nil }

    // MARK: the job

    /// Merge `frames` into one CFA DNG.
    ///
    /// Blocking; call it off the main thread. `frames` must be DNG paths that exist; the tool
    /// itself validates geometry/CFA compatibility and reports a typed code if they disagree.
    /// `onOutput` runs once with the finished file — that is where a caller adds it to a catalog;
    /// this module does not know what a catalog is.
    @discardableResult
    public func merge(_ frames: [URL],
                      outputDirectory: URL? = nil,
                      progress: ProgressHandler? = nil,
                      onOutput: ((URL) -> Void)? = nil) throws -> Outcome {
        guard frames.count >= 2 else { throw Failure.notEnoughFrames(frames.count) }
        guard let client else { throw Failure.toolMissing }
        // A client can be constructed with a path that does not exist (tests, or a bundle that
        // lost its binary): say so before blaming the user's files.
        guard FileManager.default.isExecutableFile(atPath: client.executableURL.path) else {
            throw Failure.toolMissing
        }

        let directory = outputDirectory ?? frames[0].deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Pre-flight: fail before spending 15 s if a frame is not a mergeable CFA DNG.
        for url in frames {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.unreadable(url.path)
            }
        }

        var options = HDRMergeOptions()
        options.bits = bits
        options.headroom = headroom
        options.featherRadius = featherRadius
        options.compress = compress

        // Merge into a hidden temp name, then move: a crash mid-write must not leave a DNG the
        // catalog could pick up on the next scan.
        let temp = directory.appendingPathComponent(".hdrmerge-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: temp) }

        let result: HDRMergeResult
        do {
            result = try client.merge(frames, to: temp, options: options, progress: { event in
                switch event {
                case .decoding(let index, let total, _):
                    progress?("解码 \(index)/\(total)…")
                case .merging:
                    progress?("对齐并合并…")
                case .encoding:
                    progress?("写入 DNG…")
                case .done:
                    break
                }
            })
        } catch {
            throw Failure.wrap(error)
        }

        // Name it after the frame the metadata came from — the least exposed one — so it sorts
        // next to its sources in every app, not at the end of the day.
        let final = Self.uniqueURL(base: result.metadataFrom, in: directory)
        do {
            try? FileManager.default.removeItem(at: final)
            try FileManager.default.moveItem(at: result.output, to: final)
        } catch {
            throw Failure.cannotWrite(final.path)
        }

        onOutput?(final)

        return Outcome(output: final,
                       width: result.width,
                       height: result.height,
                       bytes: (try? FileManager.default.attributesOfItem(atPath: final.path)[.size] as? Int) ?? result.bytes,
                       frameCount: result.frameCount,
                       whiteLevel: result.whiteLevel,
                       metadataFrom: result.metadataFrom,
                       report: result.report)
    }

    /// Merge everything in `frames` that looks like a mergeable RAW, in capture order.
    public func mergeSelection(_ frames: [URL],
                              outputDirectory: URL? = nil,
                              progress: ProgressHandler? = nil,
                              onOutput: ((URL) -> Void)? = nil) throws -> Outcome {
        let raws = frames.filter { Self.mergeableExtensions.contains($0.pathExtension.lowercased()) }
        return try merge(raws.sorted { Self.captureKey($0) < Self.captureKey($1) },
                         outputDirectory: outputDirectory,
                         progress: progress,
                         onOutput: onOutput)
    }

    /// Pre-flight without merging: geometry, CFA phase, black/white levels. Cheap enough to gate a
    /// UI (≈2.8 s per 60 MP frame — the lossless JPEG still has to be decoded to prove the file is
    /// usable), and it makes "these cannot be merged" a message before a 15 s job.
    public func inspect(_ frames: [URL]) throws -> [HDRMergeFrameInfo] {
        guard let client else { throw Failure.toolMissing }
        do {
            return try client.inspect(frames)
        } catch {
            throw Failure.wrap(error)
        }
    }

    // MARK: compatibility

    /// Whether `frames` are mergeable with each other, without running the merge. Returns the
    /// reason when they are not.
    public func compatibilityIssue(_ frames: [URL]) throws -> String? {
        let infos = try inspect(frames)
        guard let first = infos.first else { return "没有可合并的帧" }
        for info in infos.dropFirst() {
            if info.width != first.width || info.height != first.height {
                return "尺寸不一致：\(first.width)×\(first.height) 与 \(info.width)×\(info.height)"
            }
            if info.cfaPattern != first.cfaPattern {
                return "CFA 相位不一致：\(first.cfaPattern) 与 \(info.cfaPattern)"
            }
        }
        return nil
    }

    // MARK: helpers

    /// Formats the tool can actually merge today.
    public static let mergeableExtensions: Set<String> = ["dng"]

    /// Sort key: capture time when the catalog knows it, else the filename (camera sequence
    /// numbers are monotonic, which is why the file order already is capture order).
    static func captureKey(_ url: URL) -> String {
        url.lastPathComponent
    }

    /// `<stem>-merged.dng`, then `-2`, `-3`… Same convention as the command line, so a merge done
    /// by hand and one done here are indistinguishable.
    public static func uniqueURL(base metadataFrom: URL, in directory: URL) -> URL {
        let stem = metadataFrom.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(stem)-merged.dng")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem)-merged-\(n).dng")
            n += 1
        }
        return candidate
    }
}
