// PhotonsDepth — Depth Anything V2 Small (Core ML, F16) inference surface.
//
// The public API below is the contract: `DepthMap`, `DepthModel`, `DepthError` and `revision` are
// referenced by the spec (task 120) and by the depth cache key.
//
// Licence: the weights are Apache-2.0 (`apple/coreml-depth-anything-v2-small`); see
// `Resources/Depth-Anything-V2-LICENSE.txt` and `THIRD_PARTY_NOTICES.md`. Never claim endorsement.
import CoreML
import CoreVideo
import Foundation
import PhotonsCore

/// A relative depth map, in the model's own units: **larger value = nearer** (the model emits disparity).
/// Consumers must not assume `0…1`; normalise first (`normalised()`), and never let the sign flip
/// between the dehaze assist and the depth mask — that is the same bug class as a mirrored mask.
public struct DepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height`, disparity (near = large). Float16 keeps a 4096-long-edge map at ~32 MB.
    public let values: [Float16]

    public init(width: Int, height: Int, values: [Float16]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// Min-max normalised copy in `0…1` (near = 1). Returns `nil` for a flat map (no range to stretch).
    public func normalised() -> DepthMap? {
        var minimum = Float.greatestFiniteMagnitude
        var maximum = -Float.greatestFiniteMagnitude
        for value in values {
            let f = Float(value)
            guard f.isFinite else { continue }
            minimum = min(minimum, f)
            maximum = max(maximum, f)
        }
        guard minimum <= maximum else { return nil }
        let span = maximum - minimum
        guard span > 0 else { return nil }
        let inverse = 1 / span
        let out = values.map { value -> Float16 in
            let f = Float(value)
            guard f.isFinite else { return 0 }
            return Float16((f - minimum) * inverse)
        }
        return DepthMap(width: width, height: height, values: out)
    }
}

public enum DepthError: Error, CustomStringConvertible {
    case modelMissing(String)
    case badInputSize(expected: (Int, Int), got: (Int, Int))
    case featureMismatch(String)
    case inferenceFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let what): return "depth model missing: \(what)"
        case .badInputSize(let e, let g): return "depth input size \(g) != model \(e)"
        case .featureMismatch(let s): return "depth feature mismatch: \(s)"
        case .inferenceFailed(let s): return "depth inference failed: \(s)"
        }
    }
}

/// Loads `DepthAnythingV2SmallF16.mlmodelc` from the app bundle and runs one inference per image.
///
/// The input geometry is read from `MLModelDescription` at load time — never hard-code 518×396. The
/// model card's 518 is an *evaluation* size; the description is the only truth.
public final class DepthModel: @unchecked Sendable {
    /// Bumped whenever the weights change. Part of every depth cache key; keep the weight SHA in it.
    public static let revision = "dav2s-f16@cfef6f6"

    /// Name Core ML compiles the shipped `.mlpackage` to, and the file the app bundle carries.
    public static let modelName = "DepthAnythingV2SmallF16"

    public let inputWidth: Int
    public let inputHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int

    private let model: MLModel
    private let inputName: String
    private let outputName: String
    /// `nil` when the input is an image feature; the layout when it is an `MLMultiArray`.
    private let inputArray: ArrayLayout?
    private let inputPixelFormat: OSType
    private let inputArrayDataType: MLMultiArrayDataType?
    private let inputArrayShape: [Int]
    private let outputArray: ArrayLayout?

    // MARK: - init

    public convenience init(bundle: Bundle = .main) throws {
        guard let url = Self.modelURL(in: bundle) else {
            throw DepthError.modelMissing("\(Self.modelName).mlmodelc (not in \(bundle.bundlePath))")
        }
        try self.init(modelURL: url)
    }

    /// Loads a compiled `.mlmodelc` from an explicit URL (the CLI's `--model`).
    public init(modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelURL.path) else {
            throw DepthError.modelMissing(modelURL.lastPathComponent)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits

        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: configuration)
        } catch {
            throw DepthError.modelMissing("\(modelURL.lastPathComponent) (\(error.localizedDescription))")
        }
        let description = model.modelDescription

        let inputs = description.inputDescriptionsByName
        guard inputs.count == 1, let (inputName, input) = inputs.first else {
            throw DepthError.featureMismatch(
                "expected exactly one input, description has \(inputs.keys.sorted())")
        }

        if let image = input.imageConstraint {
            self.inputWidth = image.pixelsWide
            self.inputHeight = image.pixelsHigh
            self.inputPixelFormat = image.pixelFormatType
            self.inputArray = nil
            self.inputArrayDataType = nil
            self.inputArrayShape = []
        } else if let array = input.multiArrayConstraint {
            let shape = array.shape.map { $0.intValue }
            guard let layout = ArrayLayout(shape: shape) else {
                throw DepthError.featureMismatch("unsupported input array shape \(shape)")
            }
            self.inputWidth = layout.width
            self.inputHeight = layout.height
            self.inputPixelFormat = kCVPixelFormatType_32BGRA
            self.inputArray = layout
            self.inputArrayDataType = array.dataType
            self.inputArrayShape = shape
        } else {
            throw DepthError.featureMismatch("input '\(inputName)' is neither an image nor a multi-array")
        }

        let outputs = description.outputDescriptionsByName
        guard !outputs.isEmpty else { throw DepthError.featureMismatch("model has no outputs") }
        let chosen = outputs.first { $0.value.imageConstraint != nil || $0.value.multiArrayConstraint != nil }
            ?? outputs.first!
        self.outputName = chosen.key

        if let image = chosen.value.imageConstraint {
            self.outputWidth = image.pixelsWide
            self.outputHeight = image.pixelsHigh
            self.outputArray = nil
        } else if let array = chosen.value.multiArrayConstraint {
            let shape = array.shape.map { $0.intValue }
            guard let layout = ArrayLayout(shape: shape) else {
                throw DepthError.featureMismatch("unsupported output array shape \(shape)")
            }
            self.outputWidth = layout.width
            self.outputHeight = layout.height
            self.outputArray = layout
        } else {
            self.outputWidth = self.inputWidth
            self.outputHeight = self.inputHeight
            self.outputArray = nil
        }

        self.inputName = inputName
        self.model = model
    }

    /// The compiled model inside `bundle`, or `nil`. Lookup is by name + extension rather than by
    /// guessing `Contents/Resources`, so it works for the app, a test host and `photonsctl` alike.
    public static func modelURL(in bundle: Bundle) -> URL? {
        if let url = bundle.url(forResource: modelName, withExtension: "mlmodelc") { return url }
        guard let resources = bundle.resourceURL else { return nil }
        let direct = resources.appendingPathComponent("\(modelName).mlmodelc")
        return FileManager.default.fileExists(atPath: direct.path) ? direct : nil
    }

    // MARK: - inference

    /// One inference on an already-decoded pixel buffer. Resampling to the model's input geometry
    /// happens here, from `MLImageConstraint` — the caller supplies the picture at whatever size it
    /// decoded (or rendered) it.
    public func infer(pixelBuffer: CVPixelBuffer) throws -> DepthMap {
        let provider: MLFeatureProvider
        if let layout = inputArray {
            provider = try arrayProvider(from: pixelBuffer, layout: layout)
        } else {
            let resized = try PixelBufferResize.resize(pixelBuffer, width: inputWidth,
                                                       height: inputHeight,
                                                       pixelFormat: inputPixelFormat)
            let value = MLFeatureValue(pixelBuffer: resized)
            guard value.type == .image else {
                throw DepthError.featureMismatch("input '\(inputName)' rejected the pixel buffer")
            }
            provider = try MLDictionaryFeatureProvider(dictionary: [inputName: value])
        }

        let prediction: MLFeatureProvider
        do {
            prediction = try model.prediction(from: provider)
        } catch {
            throw DepthError.inferenceFailed("\(error)")
        }
        guard let feature = prediction.featureValue(for: outputName) else {
            throw DepthError.featureMismatch("prediction has no output '\(outputName)'")
        }
        if let buffer = feature.imageBufferValue { return try map(from: buffer) }
        if let array = feature.multiArrayValue { return try map(from: array) }
        throw DepthError.featureMismatch("output '\(outputName)' is neither an image nor a multi-array")
    }

    // MARK: - input arrays (models whose input is not an image)

    private func arrayProvider(from pixelBuffer: CVPixelBuffer,
                               layout: ArrayLayout) throws -> MLFeatureProvider {
        let bgra = try PixelBufferResize.resize(pixelBuffer, width: inputWidth, height: inputHeight,
                                                pixelFormat: kCVPixelFormatType_32BGRA)
        let array = try MLMultiArray(shape: inputArrayShape.map { NSNumber(value: $0) },
                                     dataType: inputArrayDataType ?? .float32)
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(bgra) else {
            throw DepthError.inferenceFailed("resized buffer has no base address")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(bgra)
        for y in 0..<inputHeight {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<inputWidth {
                let i = x * 4
                let blue = Float(row[i]) / 255
                let green = Float(row[i + 1]) / 255
                let red = Float(row[i + 2]) / 255
                for channel in 0..<layout.channels {
                    let value = channel == 0 ? red : (channel == 1 ? green : blue)
                    let index = layout.index(channel: channel, x: x, y: y)
                    array[index] = NSNumber(value: value)
                }
            }
        }
        return try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
    }

    // MARK: - outputs

    private func map(from buffer: CVPixelBuffer) throws -> DepthMap {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw DepthError.inferenceFailed("depth output has no pixels")
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var values = [Float16](repeating: 0, count: width * height)

        switch format {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float16.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { values[y * width + x] = Float16(row[x]) }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = Float16(Float(row[x]) / 255) }
            }
        case kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB:
            let isBGRA = format == kCVPixelFormatType_32BGRA
            for y in 0..<height {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let i = x * 4
                    let blue = Float(row[isBGRA ? i : i + 3])
                    let green = Float(row[isBGRA ? i + 1 : i + 2])
                    let red = Float(row[isBGRA ? i + 2 : i + 1])
                    values[y * width + x] = Float16((0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255)
                }
            }
        default:
            throw DepthError.featureMismatch(
                "unsupported depth output pixel format \(PixelBufferResize.fourCC(format))")
        }
        return DepthMap(width: width, height: height, values: values)
    }

    private func map(from array: MLMultiArray) throws -> DepthMap {
        let shape = array.shape.map { $0.intValue }
        let layout = outputArray ?? ArrayLayout(shape: shape)
        guard let layout else {
            throw DepthError.featureMismatch("unsupported depth output array shape \(shape)")
        }
        let width = layout.width, height = layout.height
        var values = [Float16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                values[y * width + x] = Float16(array[layout.index(channel: 0, x: x, y: y)].floatValue)
            }
        }
        return DepthMap(width: width, height: height, values: values)
    }

    /// Where a channel's samples sit in a model array. The depth conversion shipped here uses an
    /// image feature; the multi-array cases keep the class usable for a re-converted model.
    struct ArrayLayout: Sendable {
        enum Kind: Sendable { case chw, hwc, hw }
        let kind: Kind
        let channels: Int
        let width: Int
        let height: Int
        let shape: [Int]

        init?(shape: [Int]) {
            guard !shape.isEmpty, shape.allSatisfy({ $0 > 0 }) else { return nil }
            self.shape = shape
            switch shape.count {
            case 2:
                self.kind = .hw; self.channels = 1
                self.height = shape[0]; self.width = shape[1]
            case 3:
                if shape[0] <= 4, shape[1] > 4, shape[2] > 4 {
                    self.kind = .chw; self.channels = shape[0]
                    self.height = shape[1]; self.width = shape[2]
                } else if shape[2] <= 4, shape[0] > 4, shape[1] > 4 {
                    self.kind = .hwc; self.channels = shape[2]
                    self.height = shape[0]; self.width = shape[1]
                } else {
                    self.kind = .hw; self.channels = 1
                    self.height = shape[1]; self.width = shape[2]
                }
            case 4:
                if shape[1] <= 4, shape[2] > 4, shape[3] > 4 {
                    self.kind = .chw; self.channels = shape[1]
                    self.height = shape[2]; self.width = shape[3]
                } else if shape[3] <= 4, shape[1] > 4, shape[2] > 4 {
                    self.kind = .hwc; self.channels = shape[3]
                    self.height = shape[1]; self.width = shape[2]
                } else {
                    return nil
                }
            default:
                return nil
            }
        }

        func index(channel: Int, x: Int, y: Int) -> [NSNumber] {
            switch kind {
            case .hw:
                return shape.count == 2 ? [NSNumber(value: y), NSNumber(value: x)]
                    : [0, NSNumber(value: y), NSNumber(value: x)]
            case .chw:
                return shape.count == 3 ? [NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]
                    : [0, NSNumber(value: channel), NSNumber(value: y), NSNumber(value: x)]
            case .hwc:
                return shape.count == 3 ? [NSNumber(value: y), NSNumber(value: x), NSNumber(value: channel)]
                    : [0, NSNumber(value: y), NSNumber(value: x), NSNumber(value: channel)]
            }
        }
    }
}
