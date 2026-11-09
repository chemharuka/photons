/// 「删掉当前这张，接着看下一张」 — the successor rule, with no UI attached.
///
/// Deleting a photo must not send the view back to the first row: the eye is on the anchor, so the
/// photo that takes its place is the next one in the **order seen before the delete**. Only when the
/// anchor was the last row does it fall back to the previous one.
///
/// Pure and static on purpose: the session keeps the rule testable without a catalog, and the same
/// function serves single- and multi-selection deletes (the anchor, not the end of the selection).
public enum SelectionAfterRemoval {

    /// - Parameters:
    ///   - order: asset ids in the order the user saw them **before** the delete.
    ///   - removing: the ids this delete removes.
    ///   - anchor: the anchor before the delete.
    /// - Returns: the id that should become the anchor after the delete. `anchor` itself when it is
    ///   not being removed (nothing to succeed), otherwise the first surviving id after it, else the
    ///   last surviving id before it, else `nil` (nothing left).
    public static func successor(order: [String], removing: Set<String>, anchor: String?) -> String? {
        guard let anchor else { return nil }
        guard removing.contains(anchor) else { return anchor }
        guard let index = order.firstIndex(of: anchor) else { return nil }
        for id in order[(index + 1)...] where !removing.contains(id) { return id }
        for id in order[..<index].reversed() where !removing.contains(id) { return id }
        return nil
    }
}
