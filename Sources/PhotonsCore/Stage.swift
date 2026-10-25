import Foundation
import CryptoKit

// MARK: - stages

/// The five stages of the editing graph (seven GPU passes), in execution order.
///
/// `RenderStage` is the unit of both the cache-key chain (D6) and group-level dirty tracking (D10).
/// Every stage boundary is a key: re-running S3 must not re-run S0/S1.
public enum RenderStage: String, CaseIterable, Sendable, Codable {
    case geometry = "s0-geometry"
    case sceneLinear = "s1-scene-linear"
    case toneMap = "s2-tone-map"
    case curve = "s3-curve"
    case color = "s3-color"
    case vignette = "s3-vignette"
    case display = "s4-display"

    public var index: Int { RenderStage.allCases.firstIndex(of: self)! }
    public var label: String { rawValue }

    /// Short alias used in trace lines (`--trace-stages`).
    public var short: String {
        switch self {
        case .geometry: return "s0"
        case .sceneLinear: return "s1"
        case .toneMap: return "s2"
        case .curve: return "s3-curve"
        case .color: return "s3-color"
        case .vignette: return "s3-vignette"
        case .display: return "s4"
        }
    }

    /// Stages whose parameters live in the same UI group; used to explain a dirty set.
    public var group: String {
        switch self {
        case .geometry: return "geometry"
        case .sceneLinear, .toneMap: return "light"
        case .curve: return "curve"
        case .color: return "color"
        case .vignette: return "effects"
        case .display: return "output"
        }
    }
}

// MARK: - geometry of a render pass

public struct ImageSize: Sendable, Equatable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public var pixelCount: Int { width * height }
    public var keyString: String { "\(width)x\(height)" }

    /// Largest size with the same aspect that fits inside `box`.
    public static func fit(_ size: ImageSize, in box: ImageSize) -> ImageSize {
        let s = min(Double(box.width) / Double(size.width), Double(box.height) / Double(size.height))
        return ImageSize(width: max(1, Int((Double(size.width) * s).rounded())),
                         height: max(1, Int((Double(size.height) * s).rounded())))
    }
}

// MARK: - output

public enum OutputPrimaries: String, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }
}

public struct DisplayOptions: Sendable, Equatable {
    public var primaries: OutputPrimaries
    public var bitDepth: Int      // 8 or 16, only affects encoding, not the render
    /// Upper bound of the display encode, in linear scene units.
    ///
    /// `1` is SDR and is **pixel-identical to the pre-EDR output** (`clamp(v, 0, 1)` became
    /// `min(v, headroom)`). Values above 1 only survive if the S4 clamp stops at `headroom`, which
    /// is why this is a contract now rather than in M3.5: opening EDR later must be one boolean and
    /// one number, not a change to S4, S2, the key chain and every golden
    /// (docs/architecture-decisions.md §11.8, item 3).
    public var headroom: Double

    public init(primaries: OutputPrimaries = .sRGB, bitDepth: Int = 8, headroom: Double = 1) {
        self.primaries = primaries
        self.bitDepth = bitDepth
        self.headroom = headroom
    }

    public var keyString: String {
        // Headroom changes the pixels, so it must change the key; "%.3f" keeps 1.0 == "1.000"
        // across processes and avoids 1 vs 1.0000000001 style churn.
        String(format: "%@;bits=%d;headroom=%.3f", primaries.rawValue, bitDepth, headroom)
    }
}

// MARK: - cache keys

/// Accumulates canonically formatted fields and digests them.
///
/// Fixed precision, fixed order, no dictionary iteration: two processes that render the same
/// document must produce the same keys, otherwise the on-disk cache is a coin flip.
public struct KeyBuilder {
    private var parts: [String] = []

    public init() {}

    public init(_ seed: String) { parts = [seed] }

    @discardableResult
    public func add(_ s: String) -> KeyBuilder {
        var c = self
        c.parts.append(s)
        return c
    }

    @discardableResult
    public func add(_ v: Int) -> KeyBuilder {
        var c = self
        c.parts.append("\(v)")
        return c
    }

    @discardableResult
    public func add(_ v: Double) -> KeyBuilder {
        var c = self
        c.parts.append(String(format: "%.5f", v))
        return c
    }

    @discardableResult
    public func add(_ size: ImageSize) -> KeyBuilder {
        var c = self
        c.parts.append(size.keyString)
        return c
    }

    public var canonical: String { parts.joined(separator: "|") }

    public func digest() -> String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The key chain for one render: each stage's output key, computed before anything runs.
public struct StageKeys: Sendable, Equatable {
    public var inputIdentity: String
    public var geometry: String
    public var sceneLinear: String
    public var toneMap: String
    public var curve: String
    public var color: String
    public var vignette: String
    public var display: String

    public func key(for stage: RenderStage) -> String {
        switch stage {
        case .geometry: return geometry
        case .sceneLinear: return sceneLinear
        case .toneMap: return toneMap
        case .curve: return curve
        case .color: return color
        case .vignette: return vignette
        case .display: return display
        }
    }

    public var shortTrace: String {
        RenderStage.allCases.map { "\($0.short)=\(key(for: $0).prefix(8))" }.joined(separator: " ")
    }
}

// MARK: - trace

/// What actually ran, what came out of the stage cache, and how long the GPU took.
public struct RenderTrace: Sendable {
    public var executed: [RenderStage] = []
    public var skipped: [RenderStage] = []
    public var gpuMilliseconds: Double = 0
    public var cacheHits: Int = 0

    public init() {}

    public mutating func record(_ stage: RenderStage, executed didRun: Bool) {
        if didRun {
            executed.append(stage)
        } else {
            skipped.append(stage)
            cacheHits += 1
        }
    }

    public var summary: String {
        let ex = executed.isEmpty ? "(none)" : executed.map(\.label).joined(separator: " ")
        let sk = skipped.isEmpty ? "(none)" : skipped.map(\.label).joined(separator: " ")
        return "stages     \(ex)\nskipped    \(sk)\ngpu        \(String(format: "%.2f", gpuMilliseconds)) ms"
    }

    /// Comma-free machine form for grepping in scripts (`--trace-stages --trace-format csv`).
    public var csv: String {
        executed.map(\.label).joined(separator: ",")
    }
}
