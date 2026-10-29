import Foundation

/// The measured map from a white-balance *request* to the **linear gain** it produces, so a drag can
/// show a real preview without a decode.
///
/// Why this exists and not a formula: the sliders are decoder inputs (`CIRAWFilter`'s
/// `temperature`/`tint`), so a preview has to predict what a re-decode would do. Measured on five
/// cameras (`~/workspace/scripts/wb_preview_probe.py`): the decode's response **is** a per-channel
/// gain on the linear buffer (drift between dark and bright mid-tones ≤ 1 %), but the map from
/// `(K, tint)` to that gain is the decoder's own business and is **not** what
/// `WhiteBalanceSolver.gain` computes — that fit is off by 32 % on average, up to 220 % at the ends.
///
/// A 9 × 5 node table with bilinear interpolation predicts off-node requests to **0.4–1.5 %**, which
/// is what makes this worth shipping. Nodes hold gains **relative to the table's `asShot`**, so
/// `gain(from:to:)` is the element-wise ratio of two nodes and does not care which pair the table was
/// measured against.
public struct WhiteBalancePreviewTable: Sendable, Codable, Equatable {

    public struct Point: Sendable, Codable, Equatable {
        public var temperature: Double
        public var tint: Double

        public init(temperature: Double, tint: Double) {
            self.temperature = temperature
            self.tint = tint
        }
    }

    /// The camera this table was measured on (`photonsctl info`'s `camera` line, e.g.
    /// `LEICA CAMERA AG / LEICA SL3  ISO 100`). Matched by substring against an asset's model.
    public let camera: String
    /// The decoder version the numbers belong to — a decoder change is a different pipeline.
    public let decoderVersion: String
    /// The pair the gains are relative to (the file's as-shot pair when measured in the field).
    public let asShot: Point
    public let temperatures: [Double]
    public let tints: [Double]
    /// `gains[tempIndex][tintIndex]` = `(r, g, b)` relative to `asShot`.
    public let gains: [[[Double]]]

    public init(camera: String, decoderVersion: String, asShot: Point,
                temperatures: [Double], tints: [Double], gains: [[[Double]]]) {
        self.camera = camera
        self.decoderVersion = decoderVersion
        self.asShot = asShot
        self.temperatures = temperatures
        self.tints = tints
        self.gains = gains
    }

    /// Does this table describe `model` (an asset's camera model string)? Case- and space-insensitive.
    public func describes(camera model: String) -> Bool {
        let norm = { (s: String) in s.lowercased().replacingOccurrences(of: " ", with: "") }
        let mine = norm(camera), theirs = norm(model)
        guard !theirs.isEmpty else { return false }
        return mine.contains(theirs) || theirs.contains(mine)
    }

    /// The gain that turns a buffer decoded at `from` into the look of `to`.
    ///
    /// `nil` when either pair falls outside the table (the caller then falls back to the analytic
    /// solver rather than extrapolating a measurement it does not have).
    public func gain(from: Point, to: Point) -> (r: Double, g: Double, b: Double)? {
        guard let a = node(from), let b = node(to) else { return nil }
        guard a.0 > 1e-6, a.1 > 1e-6, a.2 > 1e-6 else { return nil }
        return (b.0 / a.0, b.1 / a.1, b.2 / a.2)
    }

    /// Bilinear lookup, clamped to the table's own range. Returns `nil` when the table is malformed.
    public func node(_ p: Point) -> (Double, Double, Double)? {
        guard temperatures.count >= 2, tints.count >= 2,
              gains.count == temperatures.count,
              gains.allSatisfy({ $0.count == tints.count }) else { return nil }

        func locate(_ value: Double, in axis: [Double]) -> (Int, Double) {
            if value <= axis[0] { return (0, 0) }
            if value >= axis[axis.count - 1] { return (axis.count - 2, 1) }
            var i = 0
            while i < axis.count - 2, value > axis[i + 1] { i += 1 }
            let span = axis[i + 1] - axis[i]
            return (i, span > 0 ? (value - axis[i]) / span : 0)
        }

        let (ti, ft) = locate(p.temperature, in: temperatures)
        let (ii, fi) = locate(p.tint, in: tints)

        func rgb(_ t: Int, _ i: Int) -> (Double, Double, Double)? {
            let g = gains[t][i]
            guard g.count == 3 else { return nil }
            return (g[0], g[1], g[2])
        }

        guard let a = rgb(ti, ii), let b = rgb(ti + 1, ii),
              let c = rgb(ti, ii + 1), let d = rgb(ti + 1, ii + 1) else { return nil }

        func mix(_ x: Double, _ y: Double, _ f: Double) -> Double { x + (y - x) * f }
        let low = (mix(a.0, b.0, ft), mix(a.1, b.1, ft), mix(a.2, b.2, ft))
        let high = (mix(c.0, d.0, ft), mix(c.1, d.1, ft), mix(c.2, d.2, ft))
        return (mix(low.0, high.0, fi), mix(low.1, high.1, fi), mix(low.2, high.2, fi))
    }

    // MARK: - loading

    public static func load(from url: URL) throws -> WhiteBalancePreviewTable {
        try JSONDecoder().decode(WhiteBalancePreviewTable.self, from: Data(contentsOf: url))
    }

    /// Where measured tables live: `~/Library/Application Support/Photons/WhiteBalanceTables/`.
    ///
    /// Files rather than bundled resources on purpose — the tables are **produced at runtime** by the
    /// self-calibration (118 §3), so a shipped build starts with none and grows them per camera.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Photons/WhiteBalanceTables", isDirectory: true)
    }

    /// Every table in `directory` that decodes. A missing directory is not an error: a build with no
    /// calibration simply has no table and the preview falls back to the solver.
    public static func loadAll(from directory: URL = WhiteBalancePreviewTable.defaultDirectory)
        -> [WhiteBalancePreviewTable] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                 includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" } ?? []
        return urls.compactMap { try? load(from: $0) }
    }

    /// Write (or replace) this table as `directory/<camera>-v<decoderVersion>.json`.
    public func save(to directory: URL = WhiteBalancePreviewTable.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = camera.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let url = directory.appendingPathComponent("\(name)-v\(decoderVersion).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The first table that describes `model` and was measured on `decoderVersion`.
    public static func table(forCamera model: String, decoderVersion: String,
                             in tables: [WhiteBalancePreviewTable]) -> WhiteBalancePreviewTable? {
        tables.first { $0.decoderVersion == decoderVersion && $0.describes(camera: model) }
    }
}
