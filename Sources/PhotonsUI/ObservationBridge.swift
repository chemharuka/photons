import Foundation
import Observation

/// Re-arms `withObservationTracking` after every change — the whole AppKit↔`@Observable` bridge.
///
/// `withObservationTracking` fires its `onChange` **once**, before the mutation is applied, so a
/// view that just calls it re-observes nothing after one change. Re-registering inside a main-queue
/// hop both restores the tracking and lands the redraw after the new value exists. This is the
/// shape redlamp uses for its 71 `@Observable` models (`Model/FolderLibrary.swift:526`); there is no
/// second state store anywhere (research `ui-stack.md` F5).
public final class ObservationBridge: @unchecked Sendable {
    private var cancelled = false

    public init() {}

    public func cancel() { cancelled = true }

    public func observe(_ read: @escaping () -> Void, _ onChange: @escaping () -> Void) {
        guard !cancelled else { return }
        withObservationTracking {
            read()
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self, !self.cancelled else { return }
                self.observe(read, onChange)
                onChange()
            }
        }
    }
}
