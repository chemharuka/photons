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
/// already failed on this machine. `makeLibrary(source:)` needs no Xcode — the OS ships the compiler
/// — and it happens once per process, so it cannot show up in a frame-time budget.
final class KernelLibrary {
    private let device: MTLDevice
    private var libraries: [String: MTLLibrary] = [:]
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var renderPipelines: [String: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func pipeline(file: String, function: String) throws -> MTLComputePipelineState {
        let cacheKey = "\(file):\(function)"
        if let p = pipelines[cacheKey] { return p }
        let library = try library(named: file)
        guard let fn = library.makeFunction(name: function) else {
            throw RenderError.missingKernelFunction(file, function)
        }
        do {
            let p = try device.makeComputePipelineState(function: fn)
            pipelines[cacheKey] = p
            return p
        } catch {
            throw RenderError.pipelineFailed(file, error.localizedDescription)
        }
    }

    /// Render pipelines (the on-screen present pass) are compiled the same way: source from the
    /// resource bundle, pipeline cached per colour-attachment format.
    func renderPipeline(file: String, vertex: String, fragment: String,
                        pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let cacheKey = "\(file):\(vertex)+\(fragment):\(pixelFormat.rawValue)"
        if let p = renderPipelines[cacheKey] { return p }
        let library = try library(named: file)
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
            renderPipelines[cacheKey] = p
            return p
        } catch {
            throw RenderError.pipelineFailed(file, error.localizedDescription)
        }
    }

    private func library(named file: String) throws -> MTLLibrary {
        if let l = libraries[file] { return l }
        guard let url = Self.kernelSourceURL(file) else {
            throw RenderError.missingKernelSource(file)
        }
        let source = try Self.expandingLocalIncludes(of: url)
        do {
            let l = try device.makeLibrary(source: source, options: nil)
            libraries[file] = l
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
