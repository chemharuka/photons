import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

@MainActor
final class CameraBodyLibrary: ObservableObject {
    static let shared = CameraBodyLibrary()
    let store: CameraBodyStore
    @Published private(set) var custom: [PanoramaCameraBody] = []
    @Published private(set) var issues: [String] = []
    var bodies: [PanoramaCameraBody] { PanoramaCameraBody.allCases + custom }

    init(store: CameraBodyStore = CameraBodyStore()) { self.store = store; refresh() }
    func refresh() {
        let catalog = store.catalog()
        custom = catalog.custom; issues = catalog.issues
    }
    func save(_ body: PanoramaCameraBody) throws { try store.save(body); refresh() }
    func delete(_ body: PanoramaCameraBody) throws { try store.delete(body); refresh() }

    /// A task's frozen definition remains selectable even if the library copy is edited/deleted.
    func containsSnapshot(_ body: PanoramaCameraBody) -> Bool { bodies.contains(body) }
}

struct CameraBodyPicker: View {
    @Binding var selection: PanoramaCameraBody
    @ObservedObject var library: CameraBodyLibrary = .shared
    var body: some View {
        Picker(L10n.tr("ee38b80c37d9"), selection: $selection) {
            Section(L10n.tr("cameraBodies.builtIn")) {
                ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) }
            }
            if !library.custom.isEmpty {
                Section(L10n.tr("cameraBodies.custom")) {
                    ForEach(library.custom) { Text($0.name).tag($0) }
                }
            }
            if !library.containsSnapshot(selection) {
                Section(L10n.tr("cameraBodies.currentTask")) { Text(selection.name).tag(selection) }
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("cameraBody.picker")
        .onAppear { library.refresh() }
    }
}
