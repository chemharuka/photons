import AppKit

/// The rating keyboard map: **catalog metadata, not an edit**.
///
/// 0–5 stars, P pick / X reject / U clear, ⌥1–⌥6 colour labels. One press applies to the whole
/// selection (the session turns that into one transaction — see
/// `Catalog.setRating(_:forAssets:)`), and none of it touches `EditModel`, `EditHistory` or
/// `develop_json`: a rating is a library fact, so ⌘Z must not walk it back and the undo stack must
/// not grow (docs/architecture-decisions.md D10 keeps history for *document* snapshots only).
///
/// Pure mapping + one call: the grid, the filmstrip and the loupe canvas all route their `keyDown`
/// through `handle(_:session:)`, so there is exactly one table.
public enum RatingShortcuts {

    public enum Command: Equatable {
        case rating(Int)
        /// `nil` clears the flag (U).
        case flag(String?)
        /// `nil` clears the colour label.
        case colorLabel(String?)
    }

    /// The command a key event means, or nil when the event is not ours.
    ///
    /// ⌘/⌃ events are excluded on purpose: ⌘1/⌘2 already switch grid/loupe, and a shortcut table
    /// that steals a menu equivalent is worse than one that misses a key.
    public static func command(for event: NSEvent) -> Command? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.contains(.command), !flags.contains(.control) else { return nil }
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if flags.contains(.option) {
            switch key {
            case "1": return .colorLabel(ColorLabel.red.rawValue)
            case "2": return .colorLabel(ColorLabel.orange.rawValue)
            case "3": return .colorLabel(ColorLabel.yellow.rawValue)
            case "4": return .colorLabel(ColorLabel.green.rawValue)
            case "5": return .colorLabel(ColorLabel.blue.rawValue)
            case "6": return .colorLabel(ColorLabel.purple.rawValue)
            default: return nil
            }
        }

        switch key {
        case "0": return .rating(0)
        case "1": return .rating(1)
        case "2": return .rating(2)
        case "3": return .rating(3)
        case "4": return .rating(4)
        case "5": return .rating(5)
        case "p": return .flag(AssetFlag.pick.rawValue)
        case "x": return .flag(AssetFlag.reject.rawValue)
        case "u": return .flag(nil)
        default: return nil
        }
    }

    /// Apply the event to the session's selection. Returns false for "not my key", which is what
    /// lets the caller fall through to arrows, Return and the rest.
    @MainActor
    @discardableResult
    public static func handle(_ event: NSEvent, session: CatalogSession) -> Bool {
        guard let command = command(for: event) else { return false }
        switch command {
        case .rating(let stars): return session.setRatingForSelection(stars)
        case .flag(let flag): return session.setFlagForSelection(flag)
        case .colorLabel(let label): return session.setColorLabelForSelection(label)
        }
    }
}
