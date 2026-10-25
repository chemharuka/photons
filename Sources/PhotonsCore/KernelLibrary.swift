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

    private func library(named file: String) throws -> MTLLibrary {
        if let l = libraries[file] { return l }
        guard let url = Self.kernelSourceURL(file) else {
            throw RenderError.missingKernelSource(file)
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        do {
            let l = try device.makeLibrary(source: source, options: nil)
            libraries[file] = l
            return l
        } catch {
            throw RenderError.kernelCompileFailed(file, error.localizedDescription)
        }
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
