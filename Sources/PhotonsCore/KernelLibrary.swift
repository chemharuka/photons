import Foundation
import Metal

public enum RenderError: LocalizedError {
    case noMetalDevice
    case missingKernelSource(String)
    case kernelCompileFailed(String, String)
    case missingKernelFunction(String, String)
    case pipelineFailed(String, String)
    case allocationFailed(String)
    case commandBufferFailed
    case executeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noMetalDevice: return "no Metal device"
        case .missingKernelSource(let f): return "kernel source missing from bundle: \(f).metal"
        case .kernelCompileFailed(let f, let m): return "\(f).metal failed to compile: \(m)"
        case .missingKernelFunction(let f, let m): return "\(f).metal has no function '\(m)'"
        case .pipelineFailed(let f, let m): return "pipeline for \(f).metal failed: \(m)"
        case .allocationFailed(let d): return "could not allocate a \(d) texture"
        case .commandBufferFailed: return "could not create a command buffer"
        case .executeFailed(let m): return "GPU execution failed: \(m)"
        }
    }
}

/// Loads the `.metal` sources shipped in the target's resource bundle and compiles them at runtime.
///
/// Runtime compilation (rather than a prebuilt `default.metallib`) is deliberate: SwiftPM has no
/// dependable Metal-build step, and the Metal *toolchain* component is a network download that has
/// already failed on this machine. `makeLibrary(source:)` needs no Xcode — the OS ships the compiler.
///
/// 351 — **the cache is the process's, not the graph's.** It used to be per instance, on the
/// assumption that "it happens once per process". It does not: every `RenderGraph` owns one of these,
/// and the thumbnail producer builds a graph per photo, so 24 cells compiled the same nine kernels 24
/// times. Measured on 24 RAWs (release, this machine): `render` 3532 ms p50 per cell, of which
/// 499 ms was the first frame's per-graph pipeline creation alone when only one graph was alive —
/// and ~2.5 s when nine workers each compiled the same sources at once (the Metal compiler
/// serialises). `MTLLibrary` and pipeline states are immutable and the device is process-wide, so the
/// cache key is `(device, file[, function])` and the compile is done once, under one lock.
final class KernelLibrary {
    private let device: MTLDevice

    private static let cacheLock = NSLock()
    private static var libraries: [String: MTLLibrary] = [:]
    private static var pipelines: [String: MTLComputePipelineState] = [:]
    private static var renderPipelines: [String: MTLRenderPipelineState] = [:]

    /// Same device ⇒ same compiled code. `registryID` is stable for the process's device object and
    /// does not keep the device alive.
    private var deviceKey: String { "dev\(device.registryID)" }

    init(device: MTLDevice) {
        self.device = device
    }

    func pipeline(file: String, function: String) throws -> MTLComputePipelineState {
        let cacheKey = "\(deviceKey)|\(file):\(function)"
        // The lock is held across the compile on purpose: nine workers asking for the *same* file
        // must compile it once and wait, not compile it nine times in parallel (measured slower).
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let p = Self.pipelines[cacheKey] { return p }
        let library = try libraryLocked(named: file)
        guard let fn = library.makeFunction(name: function) else {
            throw RenderError.missingKernelFunction(file, function)
        }
        do {
            let p = try device.makeComputePipelineState(function: fn)
            Self.pipelines[cacheKey] = p
            return p
        } catch {
            throw RenderError.pipelineFailed(file, error.localizedDescription)
        }
    }

    /// Render pipelines (the on-screen present pass) are compiled the same way: source from the
    /// resource bundle, pipeline cached per colour-attachment format — and, like `pipeline`, per
    /// **(device, file, functions, pixel format)** rather than per graph (351).
    func renderPipeline(file: String, vertex: String, fragment: String,
                        pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let cacheKey = "\(deviceKey)|\(file):\(vertex)+\(fragment):\(pixelFormat.rawValue)"
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let p = Self.renderPipelines[cacheKey] { return p }
        let library = try libraryLocked(named: file)
        guard let vfn = library.makeFunction(name: vertex) else {
            throw RenderError.missingKernelFunction(file, vertex)
        }
        guard let ffn = library.makeFunction(name: fragment) else {
            throw RenderError.missingKernelFunction(file, fragment)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = cacheKey
        desc.vertexFunction = vfn
        desc.fragmentFunction = ffn
        desc.colorAttachments[0].pixelFormat = pixelFormat
        do {
            let p = try device.makeRenderPipelineState(descriptor: desc)
            Self.renderPipelines[cacheKey] = p
            return p
        } catch {
            throw RenderError.pipelineFailed(file, error.localizedDescription)
        }
    }

    /// Caller holds `cacheLock`.
    private func libraryLocked(named file: String) throws -> MTLLibrary {
        let key = "\(deviceKey)|\(file)"
        if let l = Self.libraries[key] { return l }
        guard let url = Self.kernelSourceURL(file) else {
            throw RenderError.missingKernelSource(file)
        }
        let source = try Self.expandingLocalIncludes(of: url)
        do {
            let l = try device.makeLibrary(source: source, options: nil)
            Self.libraries[key] = l
            return l
        } catch {
            throw RenderError.kernelCompileFailed(file, error.localizedDescription)
        }
    }

    /// The kernel's text with every `#include "x.metal"` replaced by that file's text.
    ///
    /// 派单 056 put the HSL maths in one shared source (`color_hsl.metal`) so `s3_color` and
    /// `s3_5_local_color` compile the *same* functions instead of two copies. Metal's runtime
    /// compiler cannot do that on its own: `makeLibrary(source:)` has no include search path (it
    /// fails with "file not found"), and `makeLibrary(URL:)` wants a prebuilt metallib, not a source
    /// file. So the loader inlines the include, from the directory the kernel itself came from.
    ///
    /// Deliberately narrow: only `#include "…"` (quoted) is expanded, one level deep per file with a
    /// visited set against a cycle, and `<…>` system includes are left for the compiler. A shared
    /// header that a kernel asks for must exist next to it — a missing one is an error, not a no-op.
    static func expandingLocalIncludes(of url: URL, visited: Set<String> = []) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        let name = url.lastPathComponent
        guard !visited.contains(name) else {
            throw RenderError.kernelCompileFailed(name, "include cycle at \(name)")
        }
        var visited = visited
        visited.insert(name)
        var out: [String] = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#include \""), trimmed.hasSuffix("\"") else {
                out.append(String(line))
                continue
            }
            let start = trimmed.index(trimmed.startIndex, offsetBy: 10)
            let includeName = String(trimmed[start..<trimmed.index(before: trimmed.endIndex)])
            let sibling = url.deletingLastPathComponent().appendingPathComponent(includeName)
            guard FileManager.default.fileExists(atPath: sibling.path) else {
                throw RenderError.missingKernelSource(includeName)
            }
            out.append("// ── inlined from \(includeName) ──")
            out.append(try expandingLocalIncludes(of: sibling, visited: visited))
            out.append("// ── end \(includeName) ──")
        }
        return out.joined(separator: "\n")
    }

    /// Kernels are declared as a copied resource directory (`Kernels/`), so they land untouched in
    /// the target bundle next to the compiled code.
    static func kernelSourceURL(_ file: String) -> URL? {
        let bundle = Bundle.module
        if let u = bundle.url(forResource: file, withExtension: "metal", subdirectory: "Kernels") {
            return u
        }
        if let u = bundle.url(forResource: "Kernels/\(file)", withExtension: "metal") {
            return u
        }
        return nil
    }

    static var availableKernelFiles: [String] {
        let dir = Bundle.module.url(forResource: "Kernels", withExtension: nil)
        guard let dir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        return files.filter { $0.hasSuffix(".metal") }.sorted()
    }
}
