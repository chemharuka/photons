#if os(iOS)
import SwiftUI

/// Full-screen settings leave room for the lens/calibration workflow to grow independently.
struct MobileSettingsWorkspace: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TabView {
            NavigationStack { MobileSettingsView(model: model).toolbar { close } }
                .tabItem { Label("General", systemImage: "gearshape") }
            NavigationStack { MobileSettingsView(libraryOnly: true, model: model).toolbar { close } }
                .tabItem { Label("Photo library", systemImage: "photo.stack") }
            NavigationStack { MobileProfilesSheet(model: model).toolbar { close } }
                .tabItem { Label("Lens profiles", systemImage: "camera.aperture") }
        }.preferredColorScheme(.dark).tint(.orange).accessibilityIdentifier("settings-workspace")
    }
    @ToolbarContentBuilder private var close: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("close-settings") }
    }
}
#endif
