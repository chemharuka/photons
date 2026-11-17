import PhotonsLocalization
import AppKit
import SwiftUI
import Metal
import PhotonsCore

/// A process-wide target keeps ⌘, working with an export/tool window in front, too.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public static let shared = SettingsWindowController()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 550),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = L10n.tr("df3d58c7d84b")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView())
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("PhotonsSettings")
    }
    public required init?(coder: NSCoder) { fatalError("no nib") }

    @objc public func openSettings(_ sender: Any?) {
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum SettingsPage: String, CaseIterable, Identifiable {
    case general, workspace, hdr, performance, libraries, cache
    var id: String { rawValue }
    var title: String {
        switch self { case .cache: return L10n.tr("cache.title"); case .general: return L10n.tr("835b700e028c"); case .libraries: return L10n.tr("df3be042e1cf"); case .workspace: return L10n.tr("37979829426b"); case .hdr: return L10n.tr("f02381de45eb"); case .performance: return L10n.tr("58d26314335d") }
    }
    var symbol: String {
        switch self { case .cache: return "internaldrive"; case .general: return "gearshape"; case .libraries: return "photo.stack"; case .workspace: return "rectangle.3.group"; case .hdr: return "sun.max"; case .performance: return "cpu" }
    }
    var subtitle: String {
        switch self {
        case .cache: return L10n.tr("cache.subtitle")
        case .general: return L10n.tr("acb3664262f1")
        case .libraries: return L10n.tr("74ff79c4bef3")
        case .workspace: return L10n.tr("886ed0494986")
        case .hdr: return L10n.tr("3c98d56527cc")
        case .performance: return L10n.tr("727c570a573c")
        }
    }
}

enum GeneralSettingsTab { case preferences, cameraBodies, lenses }

struct SettingsView: View {
    @State private var page: SettingsPage = .general
    @State private var generalTab: GeneralSettingsTab
    @Bindable private var preferences = ApplicationPreferences.shared
    @State private var backdrop = CanvasBackdrop.current
    @State private var concurrency = ProcessingPreferences.thumbnailConcurrency
    private let deviceName = MTLCreateSystemDefaultDevice()?.name
    private let cameraBodyLibrary: CameraBodyLibrary
    private let lensLibrary: LCCProfileLibraryModel

    init(generalTab: GeneralSettingsTab = .preferences, cameraBodyLibrary: CameraBodyLibrary = .shared,
         lensLibrary: LCCProfileLibraryModel = .shared) {
        _generalTab = State(initialValue: generalTab)
        self.cameraBodyLibrary = cameraBodyLibrary
        self.lensLibrary = lensLibrary
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("PHOTONS").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .tracking(2).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 22)
                ForEach(SettingsPage.allCases) { item in
                    Button { page = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: page == item ? .semibold : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(page == item ? Color.primary.opacity(0.09) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("settings.page.\(item.rawValue)")
                    .accessibilityAddTraits(page == item ? .isSelected : [])
                }
                Spacer()
                Text(L10n.tr("6746e89bd14e")).font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
            }
            .padding(.horizontal, 12).frame(width: 172)
            .background(Color(nsColor: StudioTheme.panel))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(page.title).font(.system(size: 23, weight: .semibold))
                Text(page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        switch page {
                        case .general: general
                        case .libraries: LibraryHistoryView()
                        case .workspace: workspace
                        case .hdr: hdr
                        case .performance: performance
                        case .cache: PreviewCacheSettingsView()
                        }
                    }.padding(.top, 20).padding(.bottom, 16)
                }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: StudioTheme.raised))
        .onReceive(NotificationCenter.default.publisher(for: .canvasBackdropDidChange)) { _ in
            backdrop = CanvasBackdrop.current
        }
        .onReceive(NotificationCenter.default.publisher(for: .photonsPreferencesDidChange)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in refreshStatus() }
    }

    @AppStorage("photons.language") private var language = L10n.defaultLanguage
    private var general:some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker(L10n.tr("835b700e028c"), selection: $generalTab) {
                Text(L10n.tr("cameraBodies.generalTab")).tag(GeneralSettingsTab.preferences)
                Text(L10n.tr("cameraBodies.title")).tag(GeneralSettingsTab.cameraBodies)
                Text(L10n.tr("lensInfo.title")).tag(GeneralSettingsTab.lenses)
            }.pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("settings.general.tabs")
            switch generalTab {
            case .preferences: generalOptions
            case .cameraBodies: CameraBodySettingsView(library: cameraBodyLibrary)
            case .lenses: LensInfoSettingsView(model: lensLibrary)
            }
        }
    }
    private var generalOptions:some View {
        VStack(alignment:.leading,spacing:18) {
        group(L10n.tr("9f6fee1aba17")) {
            Picker(L10n.tr("da9054ac44be"),selection:$language) {
                Text(L10n.tr("4eaa632ed776")).tag("zh-Hans");Text("English").tag("en")
            }.accessibilityIdentifier("settings.language")
            Text(L10n.tr("ee45ba7af403")).settingsHint()
        }
        group(L10n.tr("5467922dce50")) {
            Picker(L10n.tr("settings.historyDepth"),selection:$preferences.historyDepth) {
                ForEach(ApplicationPreferences.historyDepthOptions,id:\.self) {Text(L10n.tr("settings.historyCount",String($0))).tag($0)}
            }.accessibilityIdentifier("settings.historyDepth")
            Text(L10n.tr("settings.historyHint")).settingsHint()
        }
        }
    }
    private var workspace: some View {
        Group {
            group(L10n.tr("86a63f23a076")) {
                Picker(L10n.tr("785d65c70fde"), selection: $preferences.appearance) {
                    ForEach(WorkspaceAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.appearance")
                Text(L10n.tr("8e8cb3a30cd2")).settingsHint()
            }
            group(L10n.tr("3906276fd1bd")) {
                Picker(L10n.tr("971d8601d9ef"), selection: Binding(get: { backdrop }, set: {
                    backdrop = $0; CanvasBackdrop.set($0)
                })) {
                    Text(L10n.tr("79551187b83c")).tag(CanvasBackdrop.dark)
                    Text(L10n.tr("4f0126e18c78")).tag(CanvasBackdrop.midGrey)
                    Text(L10n.tr("fe07a094f39e")).tag(CanvasBackdrop.light)
                }.accessibilityIdentifier("settings.canvasBackdrop")
                Text(L10n.tr("6d2382ffa01b")).settingsHint()
            }
            group(L10n.tr("56410fc65314")) {
                Toggle(L10n.tr("ab39ddf5d95d"), isOn: $preferences.reopenLibrary)
                    .accessibilityIdentifier("settings.reopenLibrary")
            }
        }
    }

    private var hdr: some View {
        Group {
            group(L10n.tr("ef14a0c17fbe")) {
                Toggle(L10n.tr("03e08145d393"), isOn: $preferences.hdrPreview)
                    .accessibilityIdentifier("settings.hdrPreview")
                Text(L10n.tr("5ccdb424dd76"))
                    .settingsHint()
            }
            group(L10n.tr("c71d0bca46eb")) {
                Label(L10n.tr("10c90668a3ab"), systemImage: "photo.badge.checkmark")
                Text(L10n.tr("4cc9cdf1a1d8"))
                    .settingsHint()
                Text(L10n.tr("12395fe07d46")).settingsHint()
            }
        }
    }

    private var performance: some View {
        Group {
            group(L10n.tr("018be97547b4")) {
                Picker(L10n.tr("0fb008493588"), selection: $preferences.processing) {
                    ForEach(ProcessingPolicy.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.processing")
                Text(L10n.tr("bb7c48e8d7fc"))
                    .settingsHint()
                LabeledContent(L10n.tr("0a418653465e"), value: "\(concurrency)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            group(L10n.tr("70a474eff9ef")) {
                LabeledContent(L10n.tr("ec2dfc19ec2f"), value: deviceName == nil ? L10n.tr("a3073210cfd1") : L10n.tr("6b522b15a417"))
                if let deviceName { Text(deviceName).settingsHint() }
                Text(L10n.tr("50456a97e64e")).settingsHint()
                Divider().padding(.vertical, 3)
                Toggle(L10n.tr("b43d3c8a5e31"), isOn: $preferences.denoiseGPU)
                    .disabled(deviceName == nil)
                    .accessibilityIdentifier("settings.denoiseGPU")
                Text(L10n.tr("e4be6cfc2997"))
                    .settingsHint()
            }
        }
    }

    private func refreshStatus() { concurrency = ProcessingPreferences.thumbnailConcurrency }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content().font(.system(size: 13))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func settingsHint() -> some View {
        font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .lineSpacing(3)
    }
}
