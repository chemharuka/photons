import PhotonsLocalization
import AppKit
import Observation

/// Application policy only. Photo edits and export recipes never read these defaults.
public enum WorkspaceAppearance: String, CaseIterable, Sendable {
    case dark, light, system
    public var title: String {
        switch self { case .dark: return L10n.tr("a6b75d068032"); case .light: return L10n.tr("aa0819dfc4d8"); case .system: return L10n.tr("217cfe7db1e3") }
    }
    var appearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        case .system: return nil
        }
    }
}

public enum ProcessingPolicy: String, CaseIterable, Sendable {
    case automatic, responsive, economical
    public var title: String {
        switch self {
        case .automatic: return L10n.tr("f261d33274d7")
        case .responsive: return L10n.tr("2822bd0c1053")
        case .economical: return L10n.tr("758d05bff127")
        }
    }

    /// Bound RAW thumbnail work by both memory and CPU, not CPU count alone. Each worker owns
    /// a decoder, CIContext and graph. Pressure always wins, including in performance mode.
    public func thumbnailConcurrency(processors: Int, memory: UInt64,
                                     lowPower: Bool, thermal: ProcessInfo.ThermalState) -> Int {
        if thermal == .serious || thermal == .critical { return 1 }
        if self == .economical || (self == .automatic && lowPower) { return 1 }
        let cpuLimit = max(1, processors - 1)
        let memoryLimit = max(1, Int(memory / (2 * 1_024 * 1_024 * 1_024)))
        return min(cpuLimit, memoryLimit, self == .responsive ? 8 : 4)
    }
}

public extension Notification.Name {
    static let photonsPreferencesDidChange = Notification.Name("photons.preferencesDidChange")
}

@MainActor @Observable
public final class ApplicationPreferences {
    public static let shared = ApplicationPreferences()
    public enum Key {
        public static let appearance = "photons.workspaceAppearance"
        public static let hdrPreview = "photons.hdrPreviewEnabled"
        public static let processing = "photons.processingPolicy"
        public static let denoiseGPU = "photons.denoiseUseGPU"
        public static let reopenLibrary = "photons.reopenLastLibrary"
        public static let historyDepth = "photons.historyDepth"
    }
    @ObservationIgnored private let defaults: UserDefaults
    public static let historyDepthOptions = [10, 20, 50, 100]
    public var historyDepth: Int {
        didSet {
            if !Self.historyDepthOptions.contains(historyDepth) { historyDepth = 20 }
            persist(historyDepth, key: Key.historyDepth, changed: historyDepth != oldValue)
        }
    }
    public var appearance: WorkspaceAppearance {
        didSet { persist(appearance.rawValue, key: Key.appearance, changed: appearance != oldValue) }
    }
    public var hdrPreview: Bool {
        didSet { persist(hdrPreview, key: Key.hdrPreview, changed: hdrPreview != oldValue) }
    }
    public var processing: ProcessingPolicy {
        didSet { persist(processing.rawValue, key: Key.processing, changed: processing != oldValue) }
    }
    public var denoiseGPU: Bool {
        didSet { persist(denoiseGPU, key: Key.denoiseGPU, changed: denoiseGPU != oldValue) }
    }
    public var reopenLibrary: Bool {
        didSet { persist(reopenLibrary, key: Key.reopenLibrary, changed: reopenLibrary != oldValue) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let depth = defaults.integer(forKey: Key.historyDepth)
        historyDepth = Self.historyDepthOptions.contains(depth) ? depth : 20
        appearance = WorkspaceAppearance(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .dark
        hdrPreview = defaults.object(forKey: Key.hdrPreview) as? Bool ?? true
        processing = ProcessingPolicy(rawValue: defaults.string(forKey: Key.processing) ?? "") ?? .automatic
        denoiseGPU = defaults.object(forKey: Key.denoiseGPU) as? Bool ?? true
        reopenLibrary = defaults.object(forKey: Key.reopenLibrary) as? Bool ?? true
    }

    private func persist(_ value: Any, key: String, changed: Bool) {
        guard changed else { return }
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: .photonsPreferencesDidChange, object: self,
                                        userInfo: ["key": key])
    }
}

/// Nonisolated snapshots for render workers. UserDefaults provides its own synchronization.
enum ProcessingPreferences {
    static var hdrPreview: Bool {
        UserDefaults.standard.object(forKey: "photons.hdrPreviewEnabled") as? Bool ?? true
    }
    static var thumbnailConcurrency: Int {
        let policy = ProcessingPolicy(rawValue: UserDefaults.standard.string(forKey: "photons.processingPolicy") ?? "") ?? .automatic
        let process = ProcessInfo.processInfo
        return policy.thumbnailConcurrency(processors: process.activeProcessorCount,
            memory: process.physicalMemory, lowPower: process.isLowPowerModeEnabled,
            thermal: process.thermalState)
    }
}

/// One process-wide observer; no polling timers and no per-cell power observers.
@MainActor
public final class ApplicationPreferencesRuntime {
    public static let shared = ApplicationPreferencesRuntime()
    private var observers: [NSObjectProtocol] = []
    private init() {}
    public func start() {
        guard observers.isEmpty else { return }
        NSApp.appearance = ApplicationPreferences.shared.appearance.appearance
        _ = ProcessInfo.processInfo.thermalState
        for name in [Notification.Name.photonsPreferencesDidChange,
                     .NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if note.userInfo?["key"] as? String == ApplicationPreferences.Key.appearance {
                        NSApp.appearance = ApplicationPreferences.shared.appearance.appearance
                    }
                    ThumbnailProvider.updateProcessingPolicy()
                }
            })
        }
        ThumbnailProvider.updateProcessingPolicy()
    }
}
