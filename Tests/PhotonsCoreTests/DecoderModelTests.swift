import XCTest
import CoreImage
@testable import PhotonsCore

/// 解码模型 — the decoder side (owner, 2026-10-27).
///
/// The document stores **one item of the file's own `supportedDecoderVersions` list**, assigned
/// verbatim; the read-back is the truth. Measured on this machine (`photonsctl detail`, `L1030433.dng`,
/// SL3): `8` → `08193a35…`, `8.dng` → `a15055fa…`, `9.dng` → `f4d7e53b…`, and bare `9` is **not
/// offered** — it reads back `8` (`08193a35…`, identical to v8), with no error anywhere.
///
/// What is pinned here:
///
///  1. **Every offered spelling lands; an un-offered one reports its fallback.** `9.dng` really runs v9,
///     bare `9` really runs v8 and says so (`downgraded`).
///  2. **The four amounts are assigned only where the seam says they reach pixels** — under v9.dng that
///     is 降噪 and 锐化 only: 色彩降噪 / 细节 produce **bit-identical** pixels to the untouched document,
///     while 降噪 and 锐化 must move them (Apple: `isColorNoiseReductionSupported` / `isDetailSupported`
///     false, `isLuminanceNoiseReductionSupported` / `isSharpnessSupported` true).
///  3. **The default document does not move**: `nil` = no assignment = `ver=auto` = no new JSON field.
///  4. **The version is a decode input, not a render input.**
final class DecoderModelTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func decoder() throws -> RAWDecoder { try RAWDecoder() }

    /// A rung-sized decode: 0.2 of a 60 MP frame keeps the assertions honest and the suite fast.
    private let probeScale: Float = 0.2

    // MARK: - 1. the list and the read-back

    func testTheFilePublishesItsOwnVersionList() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        let caps = try decoder().decodeDetailed(url, options: DecodeOptions(scale: probeScale)).capabilities
        print("MODEL offered \(offered) · default v\(caps.defaultVersion) · effective v\(caps.effectiveVersion)")
        XCTAssertEqual(caps.supportedVersions, offered,
                       "the picker offers exactly what the file supports, in the file's order")
        XCTAssertEqual(caps.effectiveVersion, caps.defaultVersion,
                       "with no request, the effective version is the filter's own default")
    }

    /// `9.dng` is a real v9 decode; there is no "family" magic — the spelling is the assignment.
    func testAnOfferedSpellingLandsAndAnUnOfferedOneFallsBack() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)

        if offered.contains("9.dng") {
            let v9 = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "9.dng",
                                                                            scale: probeScale))
            XCTAssertEqual(v9.capabilities.effectiveVersion, "9.dng")
            XCTAssertEqual(v9.image.decoderVersion, "9.dng")
            XCTAssertFalse(v9.capabilities.downgraded)
        }

        if offered.contains("8.dng") {
            let v8dng = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8.dng",
                                                                                scale: probeScale))
            XCTAssertEqual(v8dng.capabilities.effectiveVersion, "8.dng",
                           "8 and 8.dng are different decodes; the read-back must keep them apart")
        }

        // The case the whole read-back exists for: a spelling this file does not offer. It is not an
        // error, it is a silent no-op inside the filter — so the capability has to say what ran.
        guard let refused = DecoderCapabilities.knownVersions.first(where: { !offered.contains($0) }) else {
            throw XCTSkip("this file offers every known version")
        }
        let fallback = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: refused,
                                                                              scale: probeScale))
        print("MODEL refused v\(refused) of \(offered) → effective v\(fallback.capabilities.effectiveVersion)")
        XCTAssertEqual(fallback.capabilities.requestedVersion, refused)
        XCTAssertTrue(fallback.capabilities.downgraded)
        XCTAssertTrue(fallback.capabilities.effectiveVersion.hasPrefix("8")
                      || fallback.capabilities.effectiveVersion == fallback.capabilities.defaultVersion)
        XCTAssertEqual(fallback.image.decoderVersion, fallback.capabilities.effectiveVersion)
    }

    // MARK: - 2. the seam decides which of the four amounts are assigned

    /// **The claim this task corrected.** Under v9 exactly two of the four amounts never reach the
    /// filter — 色彩降噪 and 细节 — and the other two still do. Measured full size, because the sharpen
    /// stage only runs at scale 1 (v8's sharpness moves 0 samples on a 0.25 rung), so "锐化 is alive
    /// under v9" cannot be shown on a preview rung.
    ///
    /// The old version of this test asserted "a v9 document with four loud amounts is bit-identical to
    /// the untouched one" — it passed only because `DetailAxes.forDecoderVersion("9…")` returned an
    /// all-off set, i.e. because the app was **withholding two sliders that work**.
    func testV9SuppressesOnlyColourNRAndDetail() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        // Sequential, one image alive at a time: a full-size 60 MP rgba16Float buffer is ~480 MB.
        let bare = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "9.dng",
                                                                           scale: 1)).image.sha256()
        var shas: [DetailAxis: String] = [:]
        var applied: [DetailAxis: DetailDecodeValues] = [:]
        for axis in DetailAxis.panelOrder {
            var loud = DetailSettings.identity
            loud[axis] = 100
            let out = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "9.dng",
                                                                              scale: 1, detail: loud))
            shas[axis] = out.image.sha256()
            applied[axis] = out.detailApplied
        }
        let row = DetailAxis.panelOrder.map { axis in
            "\(axis.title)=\(shas[axis] == bare ? "same" : "moves")(\(shas[axis]!.prefix(12)))"
        }
        print("MODEL v9 full-size sha bare=\(bare.prefix(12)) · " + row.joined(separator: " "))

        // Dead under v9 — Apple says unsupported and the pixels agree.
        XCTAssertEqual(shas[.colorNR], bare,
                       "色彩降噪 moves v9 pixels; it must not (isColorNoiseReductionSupported = false)")
        XCTAssertEqual(shas[.detail], bare,
                       "细节 moves v9 pixels; it must not (isDetailSupported = false)")
        XCTAssertNil(applied[.colorNR]?.colorNR, "v9 must not even assign 色彩降噪")
        XCTAssertNil(applied[.detail]?.detail, "v9 must not even assign 细节")

        // Alive under v9 — greying these was the bug: the slider must still reach the pixels.
        XCTAssertNotEqual(shas[.luminanceNR], bare,
                          "降噪 moves no v9 pixels but Apple reports it supported (0.021 maxΔ measured)")
        XCTAssertNotEqual(shas[.sharpness], bare,
                          "锐化 moves no v9 pixels but Apple reports it supported (0.510 maxΔ measured)")
        XCTAssertNotNil(applied[.luminanceNR]?.luminanceNR, "v9 must still assign 降噪")
        XCTAssertNotNil(applied[.sharpness]?.sharpness, "v9 must still assign 锐化")

        // The seam itself, and the v8 control at rung size (v8 assigns all four; colour NR is live
        // there — the proof that a v9 hash equality means something).
        let axes = DetailAxes.forDecoderVersion("9.dng")
        XCTAssertEqual(axes, .v9)
        XCTAssertTrue(axes.nr); XCTAssertFalse(axes.cnr)
        XCTAssertFalse(axes.detail); XCTAssertTrue(axes.sharpness)

        let loud = DetailSettings(luminanceNR: 100, colorNR: 100, sharpness: 100, detail: 100)
        let v8Bare = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8",
                                                                            scale: probeScale))
        let v8Loud = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8",
                                                                            scale: probeScale,
                                                                            detail: loud))
        let v8dngBare = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8.dng",
                                                                                scale: probeScale))
        let v8dngLoud = try decoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "8.dng",
                                                                                scale: probeScale,
                                                                                detail: loud))
        print("MODEL v8 \(v8Bare.image.sha256().prefix(16))/\(v8Loud.image.sha256().prefix(16))"
              + " · v8.dng \(v8dngBare.image.sha256().prefix(16))/\(v8dngLoud.image.sha256().prefix(16))")

        XCTAssertFalse(v8Loud.detailApplied.isEmpty, "v8 assigns the four")
        XCTAssertNotEqual(v8Loud.image.sha256(), v8Bare.image.sha256(),
                          "v8 honours colour NR — the control that proves the v9 hash means something")
        XCTAssertFalse(v8dngLoud.detailApplied.isEmpty, "v8.dng assigns too (its live axes differ)")

        XCTAssertTrue(DetailAxes.forDecoderVersion("8").anyEnabled)
        XCTAssertTrue(DetailAxes.forDecoderVersion("8.dng").anyEnabled)
    }

    // MARK: - 3. the default document does not move

    func testTheNeutralDocumentStillAsksForNothing() throws {
        let neutral = EditModel.neutral
        XCTAssertNil(neutral.decoderVersion)
        XCTAssertTrue(neutral.decodeInputs.key.contains("ver=auto"), neutral.decodeInputs.key)

        let text = String(decoding: try JSONEncoder().encode(neutral), as: UTF8.self)
        XCTAssertFalse(text.contains("decoderVersion"),
                       "a default document must not grow a field: \(text)")

        var v9 = neutral
        v9.decoderVersion = "9.dng"
        let v9Text = String(decoding: try JSONEncoder().encode(v9), as: UTF8.self)
        XCTAssertTrue(v9Text.contains("decoderVersion"), v9Text)
        let back = try JSONDecoder().decode(EditModel.self, from: Data(v9Text.utf8))
        XCTAssertEqual(back.decoderVersion, "9.dng")
        XCTAssertEqual(back.decodeInputs.key, v9.decodeInputs.key)
    }

    // MARK: - 4. decode input, not render input

    /// A version switch costs **one development** — no more. (The loupe's ladder identity is built from
    /// `DecodeInputs`, so a new version is a new rung by construction; this counts the decodes the
    /// decoder was actually asked to perform.)
    func testEachVersionCostsOneDevelopment() throws {
        let url = try fixtureURL()
        RAWDecoder.resetDecodeCounts()
        let d = try decoder()
        for version in ["8", "8.dng", "9.dng"] {
            _ = try d.decodeDetailed(url, options: DecodeOptions(decoderVersion: version,
                                                                 scale: probeScale))
        }
        XCTAssertEqual(RAWDecoder.decodeCounts()[probeScale], 3,
                       "three distinct versions = three developments, one each")
        print("MODEL decodes at scale \(probeScale): \(RAWDecoder.decodeCounts())")
    }

    func testTheVersionIsADecodeInputAndNotARenderInput() {
        var v9 = EditModel.neutral
        v9.decoderVersion = "9.dng"
        XCTAssertEqual(v9.splitFrom(.neutral), .decode,
                       "a new decoder is a new buffer, not a new render")
        XCTAssertEqual(v9.decodeInputs.key,
                       EditModel.neutral.decodeInputs.key.replacingOccurrences(of: "ver=auto",
                                                                              with: "ver=9.dng"))
        XCTAssertEqual(RenderInputs(v9), RenderInputs(EditModel.neutral),
                       "the render must not see the decoder version: the buffer already has it")
        XCTAssertEqual(v9.renderInputs.key, EditModel.neutral.renderInputs.key)

        // …and it must reach the **rung identity**, not only `key`. `appending(to:)` is the string the
        // ladder, the decode queue and `isCurrentPhoto` compare, so a version missing from it is a
        // version the canvas cannot see: measured 2026-10-27 — picking `9.dng` developed nothing (the
        // resident v8 rung "matched"), the frames hashed identically, and the only way to move the
        // picture was to drag a detail slider (which appends `dt=…`). 「选完画面不动，拖滑杆才重算」.
        XCTAssertEqual(EditModel.neutral.decodeInputs.appending(to: "photo"), "photo",
                       "the default document must still append nothing — every pre-change key is byte-identical")
        XCTAssertEqual(v9.decodeInputs.appending(to: "photo"), "photo|ver=9.dng")
        var v8dng = EditModel.neutral
        v8dng.decoderVersion = "8.dng"
        XCTAssertEqual(v8dng.decodeInputs.appending(to: "photo"), "photo|ver=8.dng",
                       "8 and 8.dng are different decodes, so they must be different rungs")
        var v9WithAmounts = v9
        v9WithAmounts.detailSettings = DetailSettings(colorNR: 30)
        XCTAssertEqual(v9WithAmounts.decodeInputs.appending(to: "photo"),
                       "photo|ver=9.dng|dt=nr·,c30,s·,d·",
                       "the version is the coarsest component and goes first")

        var both = v9
        both.detailSettings = DetailSettings(colorNR: 30)
        XCTAssertEqual(both.splitFrom(v9), .decode)
        both.decoderVersion = nil
        XCTAssertEqual(both.detailSettings, DetailSettings(colorNR: 30))
    }
}
