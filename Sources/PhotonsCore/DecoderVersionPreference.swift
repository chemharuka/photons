import CoreImage
import Foundation
import PhotonsLocalization

/// §554 — **which decoder spelling a denoise product should ask for**.
///
/// The owner's rule (2026-11-24), in their words:
///
/// > 模型降噪后，解码器版本优先选择：9 > 9.dng > 8 > 8.dng > 其他可选的
///
/// This is a **spelling** preference, not a family preference: `8` and `8.dng` are different pictures
/// (`EditModel.swift:165-172`, measured with `photonsctl detail`), and since macOS 27.3 this machine's
/// SL3 fixture lists **both bare `9` and `9.dng`** — assigning `9` reads back `9` (verified
/// 2026-11-24), so "bare 9 first" is no longer the impossible choice it was when §396 was written.
///
/// Two halves, deliberately separate:
///
///   · `preferred(in:)` / `candidates(in:)` are **pure**: they answer from the file's own
///     `supportedDecoderVersions` list and know nothing about `CIRAWFilter` runtime behaviour.
///   · `resolve(for:)` is the **read-back** half. Apple silently ignores a spelling a filter refuses
///     and keeps the previous value (`DecoderCapabilities` header), so the assignment is not the
///     answer — `filter.decoderVersion` after it is. A candidate that reads back as another spelling
///     is skipped, and the skip is recorded in `Resolution.notes`.
///
/// The user's manual 解码模型 picker is **not** touched by this type: it stores a hand-picked item
/// verbatim. This rule is only for the automatic choice a denoise product inherits.
///
/// 555 extends the same file with the **document-level** rule: a document says whether it is
/// automatic (`.auto`) or pinned to a family (`.v8` / `.v9`), and the resolver turns that — plus the
/// photo's ISO and the user's 解码偏好 — into one spelling. There is deliberately **one** automatic
/// entry point here. 409's `DecoderAutoVersion` has been folded in (Phase 2): its crop/threshold
/// helpers live here and its `requestedVersion` / `availableV9` are deleted.
public enum DecoderVersionPolicy: String, Codable, CaseIterable, Sendable {
    /// 自动 — the document stores the policy, not the spelling. The resolved spelling lives in
    /// `EditModel.resolvedDecoderVersion` and is what the cache key must name.
    case auto
    /// 手选 v8 family — pin `8` / `8.dng`, never fall through to v9.
    case v8
    /// 手选 v9 family — pin `9` / `9.dng`.
    case v9

    /// The family a hand-picked policy pins; `nil` for `.auto`.
    public var pinnedFamily: Int? {
        switch self {
        case .auto: return nil
        case .v8: return 8
        case .v9: return 9
        }
    }

    /// The policy that pins one spelling's family, or `nil` for a spelling the three-way policy
    /// cannot name (`7`, `7.dng`, …). Such a spelling is stored as the legacy hand pick
    /// (`policy = .auto`, `decoderVersion = spelling`, no resolved result) and keeps its pixels.
    public static func pinning(_ spelling: String) -> DecoderVersionPolicy? {
        let base = spelling.hasSuffix(".dng") ? String(spelling.dropLast(4)) : spelling
        switch Int(base) {
        case 8: return .v8
        case 9: return .v9
        default: return nil
        }
    }
}

public enum DecoderVersionPreference {

    /// 555 — the user's 解码偏好 in 设置 (not the document's own picker).
    ///
    /// Three values, default `.auto`. The table is `local/TASK.md` §3.2:
    ///
    /// | preference | high ISO | everything else |
    /// |---|---|---|
    /// | `.auto` | `9 > 9.dng > 8 > 8.dng > 其他` | `8 > 8.dng > 其他` |
    /// | `.preferV9` | `9 > 9.dng > 8 > 8.dng > 其他` | `9 > 9.dng > 8 > 8.dng > 其他` |
    /// | `.preferV8` | `8 > 8.dng > 其他` | `8 > 8.dng > 其他` |
    ///
    /// This is only the **setting**; a document's hand pick (`.v8` / `.v9`) ignores it. It is
    /// persisted under `settingDefaultsKey` and edited in 设置 → 解码偏好 (Phase 3).
    public enum Preference: String, Codable, CaseIterable, Sendable {
        case auto
        case preferV9
        case preferV8

        /// 555 Phase 3 — the settings row's label, in the interface language.
        public var title: String {
            switch self {
            case .auto: return Loc.t("自动")
            case .preferV9: return Loc.t("优先 v9")
            case .preferV8: return Loc.t("优先 v8")
            }
        }
    }

    /// 555 Phase 3 — the one `UserDefaults` key for 设置 → 解码偏好.
    ///
    /// Always through `AppPreferences.store`: the test process and `--ui-smoke` get their own
    /// isolated domains (466), so switching this in a test cannot rewrite the user's preference.
    public static let settingDefaultsKey = "photons.decoderVersionPreference"

    /// Posted after the setting moves, so an open document can re-resolve and re-render.
    public static let settingDidChangeNotification =
        Notification.Name("PhotonsDecoderVersionPreferenceDidChange")

    /// The stored 解码偏好. Unknown values (a downgrade, a hand-edited plist) read as 自动.
    public static var setting: Preference {
        guard let raw = AppPreferences.store.string(forKey: settingDefaultsKey),
              let stored = Preference(rawValue: raw) else { return .auto }
        return stored
    }

    /// Write the setting and tell the open document. This is the **only** writer; the settings view
    /// must not touch `UserDefaults` itself.
    public static func setSetting(_ preference: Preference) {
        guard setting != preference else { return }
        AppPreferences.store.set(preference.rawValue, forKey: settingDefaultsKey)
        NotificationCenter.default.post(name: settingDidChangeNotification, object: nil)
    }

    /// What a file offers, plus the EXIF facts the rule needs — one `CIRAWFilter`, no pixels.
    public struct DocumentFacts: Sendable, Equatable {
        public let available: [String]
        public let iso: Int?
        public let cropFactor: Double
        /// What the filter reports with nothing assigned (`8` on every body measured here). Used as
        /// the key's spelling when every candidate is rewritten, so the key never falls back to the
        /// literal `auto`.
        public let defaultVersion: String?

        public init(available: [String], iso: Int?, cropFactor: Double,
                    defaultVersion: String?) {
            self.available = available
            self.iso = iso
            self.cropFactor = cropFactor
            self.defaultVersion = defaultVersion
        }
    }

    /// The resolved spelling plus the facts that produced it — what the open path injects into a
    /// document and what the diagnostics print.
    public struct DocumentResolution: Sendable, Equatable {
        public let resolution: Resolution
        public let facts: DocumentFacts

        public init(resolution: Resolution, facts: DocumentFacts) {
            self.resolution = resolution
            self.facts = facts
        }

        /// The spelling the cache key must name: the candidate the read-back accepted, or the
        /// filter's own default when none survived. **Never** `auto`.
        public var spelling: String? { resolution.selected ?? facts.defaultVersion }
    }

    /// Read the file's facts with one filter. Cheap compared with a decode (no pixels), and cached
    /// by the session so a photo switch does not pay it twice.
    public static func facts(for url: URL) -> DocumentFacts? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let exif = RAWDecoder.exifFacts(from: filter)
        let crop = cropFactor(orFullFrame: exif.focalLength, exif.focalLength35mm)
        return DocumentFacts(available: filter.supportedDecoderVersions.map { $0.rawValue },
                             iso: exif.iso, cropFactor: crop,
                             defaultVersion: filter.decoderVersion.rawValue)
    }

    /// 555 — the full-frame ISO at or above which `.auto` / `.preferV9` may choose v9.
    ///
    /// `800` matches both the ticket's 「iso ≥ 800」 and 409's full-frame anchor. The resolver also
    /// accepts a crop factor, so the effective test is `ISO · crop² ≥ 800` (m4/3 ISO 200, APS-C
    /// ≈ 342) — the same normalisation 409 shipped, kept here so the two rules can converge without
    /// changing the meaning of 「高 ISO」. **This is the one constant to tune**; changing it must bump
    /// `DecodeRecipe.current` in the same change (Phase 2).
    public static let highISOThreshold: Double = 800

    /// 409's names, kept here now that its rule has been folded into this type.
    public static let fullFrameBaseISO: Double = highISOThreshold
    /// The crop range the `FocalLenIn35mmFilm / FocalLength` ratio is trusted in.
    public static let cropRange: ClosedRange<Double> = 0.5...4.0
    /// The crop an unreadable file is decoded at — full frame, per the owner's rule.
    public static let assumedCropFactor: Double = 1

    /// The owner's explicit order, before the deterministic fallback for everything else.
    public static let fixedOrder = ["9", "9.dng", "8", "8.dng"]

    /// One read-back attempt: the spelling handed to the filter and what the filter reported after.
    public struct ReadBack: Sendable, Equatable {
        public let candidate: String
        public let effective: String?
        public init(candidate: String, effective: String?) {
            self.candidate = candidate
            self.effective = effective
        }
    }

    /// The full answer of one selection, including why a candidate was skipped.
    public struct Resolution: Sendable, Equatable {
        /// The file's own list, in the order the decoder handed it over.
        public let available: [String]
        /// The spelling to store, or `nil` = ask for nothing (follow Apple's default).
        public let selected: String?
        /// One entry per assignment that was actually tried, in order.
        public let readBacks: [ReadBack]
        /// Human-readable readings, e.g. 「首选 9 被回读成 8」.
        public let notes: [String]

        public init(available: [String], selected: String?, readBacks: [ReadBack],
                    notes: [String]) {
            self.available = available
            self.selected = selected
            self.readBacks = readBacks
            self.notes = notes
        }
    }

    /// Every usable spelling this file offers, in the order the read-back loop should try them.
    ///
    /// `CIRAWDecoderVersionNone` is not a version (513): a JPEG answers `["None"]`, and returning it
    /// would make the caller store a spelling no RAW filter accepts.
    public static func candidates(in available: [String]) -> [String] {
        let usable = usableSpellings(in: available)

        var ordered: [String] = []
        for spelling in fixedOrder where usable.contains(spelling) {
            ordered.append(spelling)
        }
        ordered.append(contentsOf: usable
            .filter { !fixedOrder.contains($0) }
            .sorted(by: fallbackComesBefore))
        return ordered
    }

    // MARK: - 555 · policy + ISO + 解码偏好 → one candidate list

    /// 409 — 画幅比，从 EXIF 的两个焦距算出。`nil` ⇒ 调用方按全画幅处理（用户口径：
    /// 「如果算不出画幅就默认全画幅」）。
    ///
    /// Both values must exist and be positive; a ratio outside `cropRange` is treated as untrustworthy
    /// EXIF rather than as a sensor (`25 / 200 = 8.0` is not a format we know).
    public static func cropFactor(focalLength: Double?, focalLength35mm: Double?) -> Double? {
        guard let f = focalLength, let f35 = focalLength35mm, f > 0, f35 > 0 else { return nil }
        let k = f35 / f
        guard cropRange.contains(k) else { return nil }
        return k
    }

    /// The crop a file is actually decoded at: the measured one, else full frame.
    public static func cropFactor(orFullFrame focalLength: Double?,
                                  _ focalLength35mm: Double?) -> Double {
        cropFactor(focalLength: focalLength, focalLength35mm: focalLength35mm) ?? assumedCropFactor
    }

    /// `thresholdISO(crop) = 800 / crop²` — the actual-ISO value at which the equivalent ISO reaches
    /// the full-frame 800 reference (full frame 800, m4/3 200, APS-C ≈ 342).
    ///
    /// A non-positive or non-finite crop is a broken input, not a format: it answers the full-frame
    /// threshold instead of dividing by zero.
    public static func thresholdISO(crop sensorCrop: Double) -> Double {
        guard sensorCrop.isFinite, sensorCrop > 0 else { return highISOThreshold }
        return highISOThreshold / (sensorCrop * sensorCrop)
    }

    /// 409's boundary, unified with §555: `ISO · crop² ≥ 800` (the ticket changed 409's strict `>` to
    /// `≥`, so ISO exactly 800 now upgrades).
    public static func shouldUpgrade(iso: Int?, crop: Double = assumedCropFactor) -> Bool {
        isHighISO(iso: iso, cropFactor: crop)
    }

    /// `ISO · crop² ≥ 800` — the ticket's 「iso ≥ 阈值」 with 409's format normalisation.
    ///
    /// A missing ISO is **not** high ISO (we cannot prove the frame is noisy). An unreadable crop is
    /// treated as full frame (`1`), exactly as 409 did.
    public static func isHighISO(iso: Int?, cropFactor: Double = 1) -> Bool {
        guard let iso else { return false }
        let sensorCrop = cropFactor.isFinite && cropFactor > 0 ? cropFactor : 1
        return Double(iso) * sensorCrop * sensorCrop >= highISOThreshold
    }

    /// The pure answer of §555: **every** candidate the read-back loop should try, in order.
    ///
    /// The three inputs are deliberately separate:
    ///   · `policy` is the document's own 解码模型 choice;
    ///   · `preference` is the 设置 preference, which only `.auto` documents read;
    ///   · `iso` / `cropFactor` are facts about the file.
    ///
    /// `stored` is `EditModel.decoderVersion` and `resolved` is
    /// `EditModel.resolvedDecoderVersion`. The pair is what keeps pre-555 documents byte-for-byte
    /// stable: a legacy document has a `stored` spelling but **no** `resolved` result, so it is
    /// treated as the hand pick it always was. A new automatic document has `resolved` (or neither),
    /// so it follows the table. An explicit `.v8` / `.v9` document is pinned to that family, with
    /// the same family's next spelling as the read-back fallback — never the other family.
    public static func candidates(policy: DecoderVersionPolicy,
                                  preference: Preference = .auto,
                                  iso: Int?,
                                  cropFactor: Double = 1,
                                  stored: String?,
                                  resolved: String? = nil,
                                  in available: [String]) -> [String] {
        let usable = usableSpellings(in: available)

        switch policy {
        case .v8:
            return pinnedThenFamily(pinned: stored, family: 8, in: usable)
        case .v9:
            return pinnedThenFamily(pinned: stored, family: 9, in: usable)
        case .auto:
            // A stored spelling is always the user's hand pick: a pre-555 document has one and no
            // resolved result, and a Phase 2 document could carry both. The table must not move its
            // pixels; a new 自动 document stores no spelling at all.
            if let stored {
                if let family = rank(stored).major {
                    return pinnedThenFamily(pinned: stored, family: family, in: usable)
                }
                return [stored]
            }
            let allowV9 = preference == .preferV9
                || (preference == .auto && isHighISO(iso: iso, cropFactor: cropFactor))
            return allowV9 ? candidates(in: usable) : nonV9Order(in: usable)
        }
    }

    /// Apply the §555 table and **verify every assignment by reading it back**.
    ///
    /// Same read-back discipline as the 554 overload: a spelling the filter silently rewrites is
    /// skipped, and the skip is recorded. `nil` means "ask for nothing" (Apple's default).
    public static func resolve(policy: DecoderVersionPolicy,
                               preference: Preference = .auto,
                               iso: Int?,
                               cropFactor: Double = 1,
                               stored: String?,
                               resolved: String? = nil,
                               in available: [String],
                               readback: (String) -> String?) -> Resolution {
        let ordered = candidates(policy: policy, preference: preference, iso: iso,
                                 cropFactor: cropFactor, stored: stored, resolved: resolved,
                                 in: available)
        return apply(ordered, available: available,
                     emptyNote: "没有符合策略的候选，跟随默认", readback: readback)
    }

    /// The live form of the §555 resolver: one filter, its own version list, assign → read back.
    public static func resolve(policy: DecoderVersionPolicy,
                               preference: Preference = .auto,
                               iso: Int?,
                               cropFactor: Double = 1,
                               stored: String?,
                               resolved: String? = nil,
                               for url: URL) -> Resolution {
        guard let filter = CIRAWFilter(imageURL: url) else {
            return Resolution(available: [], selected: nil, readBacks: [],
                              notes: ["读不出解码器版本，跟随默认"])
        }
        let available = filter.supportedDecoderVersions.map { $0.rawValue }
        return resolve(policy: policy, preference: preference, iso: iso,
                       cropFactor: cropFactor, stored: stored, resolved: resolved,
                       in: available) { candidate in
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: candidate)
            return filter.decoderVersion.rawValue
        }
    }

    /// The pure rule: the owner's four spellings first, then the deterministic fallback.
    ///
    /// The fallback is "main version descending; at the same version the bare spelling before `.dng`;
    /// non-numeric spellings last, lexicographically". An empty (or sentinel-only) list is `nil`.
    public static func preferred(in available: [String]) -> String? {
        candidates(in: available).first
    }

    /// Apply the rule and **verify every assignment by reading it back**.
    ///
    /// `readback` is a closure so the fallback branch is testable without a RAW that refuses a
    /// spelling. The real overload below passes the live `CIRAWFilter`'s answer.
    public static func resolve(in available: [String],
                               readback: (String) -> String?) -> Resolution {
        apply(candidates(in: available), available: available,
              emptyNote: "文件没有可用的解码器版本，跟随默认", readback: readback)
    }

    /// The live form used by the denoise product: one filter, the file's own list, assign → read back.
    public static func resolve(for url: URL) -> Resolution {
        guard let filter = CIRAWFilter(imageURL: url) else {
            return Resolution(available: [], selected: nil, readBacks: [],
                              notes: ["读不出解码器版本，跟随默认"])
        }
        let available = filter.supportedDecoderVersions.map { $0.rawValue }
        return resolve(in: available) { candidate in
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: candidate)
            return filter.decoderVersion.rawValue
        }
    }

    // MARK: - shared read-back loop

    /// Assign each candidate in order, stop at the first one the filter reports back unchanged.
    ///
    /// The loop is here, once, so the 554 denoise rule and the 555 document rule cannot drift in how
    /// they treat a silent rewrite. `emptyNote` keeps the two callers' pre-existing wording.
    private static func apply(_ ordered: [String], available: [String], emptyNote: String,
                              readback: (String) -> String?) -> Resolution {
        guard !ordered.isEmpty else {
            return Resolution(available: available, selected: nil, readBacks: [],
                              notes: [emptyNote])
        }

        var readBacks: [ReadBack] = []
        var notes: [String] = []
        for candidate in ordered {
            let effective = readback(candidate)
            readBacks.append(ReadBack(candidate: candidate, effective: effective))
            if effective == candidate {
                return Resolution(available: available, selected: candidate,
                                  readBacks: readBacks, notes: notes)
            }
            notes.append("首选 \(candidate) 被回读成 \(effective ?? "nil")")
        }
        notes.append("全部候选都被改写，跟随默认")
        return Resolution(available: available, selected: nil, readBacks: readBacks, notes: notes)
    }

    // MARK: - candidate helpers

    /// The file's own list with the non-versions removed and duplicates collapsed.
    private static func usableSpellings(in available: [String]) -> [String] {
        var seen = Set<String>()
        return available.filter {
            !$0.isEmpty
                && $0 != CIRAWDecoderVersion.none.rawValue
                && seen.insert($0).inserted
        }
    }

    /// `8 > 8.dng > other non-v9 spellings`, the no-v9 half of the 555 table.
    ///
    /// v9 is excluded rather than merely deprioritised: 「优先 v8 … 不自动选 v9」 means a file whose
    /// only versions are v9 gets `nil` (ask for nothing), not a hidden upgrade.
    private static func nonV9Order(in usable: [String]) -> [String] {
        var ordered: [String] = []
        for spelling in ["8", "8.dng"] where usable.contains(spelling) {
            ordered.append(spelling)
        }
        ordered.append(contentsOf: usable
            .filter { rank($0).major != 9 && !ordered.contains($0) }
            .sorted(by: fallbackComesBefore))
        return ordered
    }

    /// `pinned` first (when it belongs to `family`), then that family's own spellings.
    ///
    /// The family's next spelling is the only fallback for a hand pick: a rejected `8` becomes
    /// `8.dng`, never `9`. A non-numeric `pinned` has no family and is tried alone.
    private static func pinnedThenFamily(pinned: String?, family: Int,
                                         in usable: [String]) -> [String] {
        var ordered: [String] = []
        if let pinned, rank(pinned).major == family {
            ordered.append(pinned)
        }
        for spelling in familyOrder(family: family, in: usable) where !ordered.contains(spelling) {
            ordered.append(spelling)
        }
        return ordered
    }

    /// `family > family.dng > other spellings of the same major version`, then nothing else.
    ///
    /// The bare spelling comes before `.dng` for every family (554's measured preference), and the
    /// remaining spellings use the same deterministic fallback as the general rule.
    private static func familyOrder(family: Int, in usable: [String]) -> [String] {
        var ordered: [String] = []
        for spelling in ["\(family)", "\(family).dng"] where usable.contains(spelling) {
            ordered.append(spelling)
        }
        ordered.append(contentsOf: usable
            .filter { rank($0).major == family && !ordered.contains($0) }
            .sorted(by: fallbackComesBefore))
        return ordered
    }

    // MARK: - deterministic fallback

    /// `(main version, is .dng)` for the spellings Apple uses (`"8"`, `"8.dng"`).
    private static func rank(_ spelling: String) -> (major: Int?, isDNG: Bool) {
        if spelling.hasSuffix(".dng") {
            let base = spelling.dropLast(4)
            return (Int(base), true)
        }
        return (Int(spelling), false)
    }

    private static func fallbackComesBefore(_ a: String, _ b: String) -> Bool {
        let ra = rank(a)
        let rb = rank(b)
        switch (ra.major, rb.major) {
        case let (x?, y?):
            if x != y { return x > y }
            if ra.isDNG != rb.isDNG { return !ra.isDNG }
            return a < b
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a < b
        }
    }
}
