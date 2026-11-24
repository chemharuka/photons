import CoreImage
import Foundation

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
public enum DecoderVersionPreference {

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
        var seen = Set<String>()
        let usable = available.filter {
            !$0.isEmpty
                && $0 != CIRAWDecoderVersion.none.rawValue
                && seen.insert($0).inserted
        }

        var ordered: [String] = []
        for spelling in fixedOrder where usable.contains(spelling) {
            ordered.append(spelling)
        }
        ordered.append(contentsOf: usable
            .filter { !fixedOrder.contains($0) }
            .sorted(by: fallbackComesBefore))
        return ordered
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
        let ordered = candidates(in: available)
        guard !ordered.isEmpty else {
            return Resolution(available: available, selected: nil, readBacks: [],
                              notes: ["文件没有可用的解码器版本，跟随默认"])
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
