import Foundation

/// What the system RAW pipeline *actually* delivers, as opposed to what was asked for.
///
/// Three facts drive this type (docs/architecture-decisions.md §11.1):
///
/// - Assigning a decoder version a body does not whitelist **silently leaves the old value in
///   place** — measured on this machine: `decoderVersion = "9"` on an SL3 file (which offers
///   `9.dng` but not bare `9`) reads back `8`; `"6"` reads back whatever was set before. There is
///   no error. So the only honest way to know the version is to read it back.
/// - Which of the four detail amounts still reach the pixels is a **per-instance** fact, and Apple
///   publishes it per instance (`isLuminanceNoiseReductionSupported` /
///   `isColorNoiseReductionSupported` / `isSharpnessSupported` / `isDetailSupported`,
///   `CIRAWFilter.h:121/129/137/153`). `detailAxes` is that answer, read off the filter that made
///   these very pixels — see `DetailAxes` for the measured table and for why the UI is driven by
///   the flags rather than by a pixel probe.
/// - v9 turns three sliders into no-ops: writing chroma noise reduction, detail or moiré reduction
///   changes zero pixels. The UI must disable them rather than let a user move a control that does
///   nothing — and it must disable **exactly** the rows `detailAxes` marks dead, never a prefix guess.
public struct DecoderCapabilities: Sendable, Equatable {
    /// The string handed to `DecodeOptions.decoderVersion`, if any.
    public let requestedVersion: String?
    /// What the filter reports after the assignment (the value that shaped these pixels).
    public let effectiveVersion: String
    /// The version the decoder was asked to use by default (v8 on every body tested so far).
    public let defaultVersion: String
    /// The **file's** own version list, in the order `supportedDecoderVersions` handed it over
    /// (`6.dng, 7, 7.dng, 8, 8.dng, 9.dng` on this machine's SL3 DNG). This is what the 解码模型 picker
    /// offers: the document stores one item of it verbatim, so `8` and `8.dng` are different choices
    /// with different pixels (measured: `08193a35…` vs `a15055fa…`) and must be distinguishable on
    /// screen.
    public let supportedVersions: [String]

    /// The request did not survive: the decoder handed back a different version.
    public var downgraded: Bool { requestedVersion.map { $0 != effectiveVersion } ?? false }

    /// **Which axes this decode honours**, read from the live `CIRAWFilter`'s own `isSupported`
    /// flags (`DetailAxes.supported(by:)`, after the version read-back and before any amount was
    /// assigned). One value, two consumers: `RAWDecoder`'s per-axis veto and `InspectorView`'s greyed
    /// rows. Nothing derives it a second time.
    public let detailAxes: DetailAxes

    /// Where `detailAxes` came from — Apple, on this very instance, or the coarse version table.
    public let detailAxesProvenance: DetailAxes.Provenance

    /// v9 removes these three (measured: writes have zero effect on the pixels). Computed from
    /// `detailAxes`, so the live-filter answer drives them too; on the fallback path they keep the
    /// version-table meaning they always had.
    public var supportsChromaNoiseReduction: Bool { detailAxes.cnr }
    public var supportsDetail: Bool { detailAxes.detail }
    public var supportsMoireReduction: Bool { detailAxes.moire }

    /// The **as-shot white balance** the decoder used for these pixels (`nil` = the filter reported
    /// nothing usable). It lives here because this is the value that travels from a development to
    /// the inspector (`DecodeRung.capabilities`): the default a document's `nil` temperature means is
    /// a fact about the decode, not a model constant (派单 006 A). It does not belong to the version
    /// facts above, but a second struct that has to be plumbed through the ladder for one pair of
    /// numbers would be worse.
    public let asShotTemperature: Double?
    public let asShotTint: Double?

    /// - Parameter detailAxes: the live filter's answer. `nil` means "no filter has decoded this
    ///   photo yet" (a hand-built value in a test, a log line): the version table stands in, and
    ///   `detailAxesProvenance` says `.versionTable` so a caller can tell the two apart.
    public init(requestedVersion: String?, effectiveVersion: String, defaultVersion: String,
                supportedVersions: [String] = [],
                detailAxes: DetailAxes? = nil,
                asShotTemperature: Double? = nil, asShotTint: Double? = nil) {
        self.requestedVersion = requestedVersion
        self.effectiveVersion = effectiveVersion
        self.defaultVersion = defaultVersion
        self.supportedVersions = supportedVersions
        if let detailAxes {
            self.detailAxes = detailAxes
            self.detailAxesProvenance = .filterFlags
        } else {
            self.detailAxes = DetailAxes.forDecoderVersion(effectiveVersion)
            self.detailAxesProvenance = .versionTable
        }
        self.asShotTemperature = asShotTemperature
        self.asShotTint = asShotTint
    }

    /// The as-shot pair as a `WhiteBalance`, for callers that only want the number.
    public var asShotWhiteBalance: WhiteBalance {
        WhiteBalance(temperature: asShotTemperature, tint: asShotTint)
    }

    /// Per-version slider availability — **the fallback**, not the capability claim. Only v9 is known
    /// to drop controls; everything below keeps the full set (v6/v7/v8 all honour them). It answers
    /// for the window before a photo has ever been decoded and for callers with no filter; the
    /// per-instance truth is `DetailAxes.supported(by:)`.
    public static func sliders(for version: String) -> (chromaNR: Bool, detail: Bool, moire: Bool) {
        let axes = DetailAxes.forDecoderVersion(version)
        return (axes.cnr, axes.detail, axes.moire)
    }

    /// Every version identifier the SDK can hand out (`CIRAWDecoderVersion` constants).
    public static let knownVersions: [String] = ["6", "6.dng", "7", "7.dng", "8", "8.dng", "9", "9.dng"]

    /// D2′ default: v8 when the file offers it, otherwise whatever Apple defaults to.
    public static func preferredDefault(offered: [String], filterDefault: String) -> String {
        if offered.contains("8") { return "8" }
        if offered.contains(filterDefault) { return filterDefault }
        return offered.first ?? filterDefault
    }

    /// Pure form of the read-back rule, so the downgrade path is testable without a RAW.
    ///
    /// Mirrors what the filter does: an assignment it does not accept leaves the previous value in
    /// place. We then force the D2′ default (v8) and report that as effective.
    public static func resolve(requested: String?,
                               offered: [String],
                               filterDefault: String) -> (effective: String, downgraded: Bool) {
        let fallback = preferredDefault(offered: offered, filterDefault: filterDefault)
        guard let wanted = requested else { return (filterDefault, false) }
        if offered.contains(wanted) { return (wanted, false) }
        return (fallback, true)
    }

    /// One line for the UI / logs. Never claims v9 when v8 ran, and never lets a table answer pass
    /// for Apple's.
    public var summary: String {
        var s = "v\(effectiveVersion)"
        if let r = requestedVersion, downgraded { s += " (requested v\(r), not offered → v\(effectiveVersion))" }
        if !supportsChromaNoiseReduction { s += " · chroma NR / detail / moiré unavailable" }
        s += " · axes[\(detailAxesProvenance.rawValue)] \(detailAxes.flagSummary)"
        return s
    }
}
