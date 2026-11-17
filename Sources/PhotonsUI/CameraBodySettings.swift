import AppKit
import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

enum CameraShiftDirection: String, CaseIterable, Identifiable {
    case left, right, up, down
    var id: String { rawValue }
    var title: String { L10n.tr("cameraBodies.direction." + rawValue) }
    func amount(in range: PanoramaShiftRange) -> Double {
        switch self { case .left: return range.left; case .right: return range.right; case .up: return range.up; case .down: return range.down }
    }
}

struct CameraBodyDraft: Identifiable {
    let id: UUID
    var name: String
    var enabled: Set<CameraShiftDirection>
    var amounts: [CameraShiftDirection: Double]
    let isNew: Bool
    init(profile: CameraBodyProfile? = nil) {
        id = profile?.id ?? UUID(); name = profile?.name ?? ""; isNew = profile == nil
        let initialAmounts = Dictionary(uniqueKeysWithValues: CameraShiftDirection.allCases.map { direction in
            (direction, profile.map { direction.amount(in: $0.travel) } ?? 0)
        })
        amounts = initialAmounts
        enabled = Set(CameraShiftDirection.allCases.filter { (initialAmounts[$0] ?? 0) > 0 })
    }
    func body() throws -> PanoramaCameraBody {
        guard enabled.allSatisfy({ let value = amounts[$0] ?? 0; return value.isFinite && value > 0 && value <= CameraBodyProfile.maximumTravel }) else {
            throw PanoramaFailure(L10n.tr("cameraBodies.enabledTravel"))
        }
        func value(_ direction: CameraShiftDirection) -> Double { enabled.contains(direction) ? amounts[direction] ?? 0 : 0 }
        return .custom(try CameraBodyProfile(id: id, name: name,
            travel: .init(left: value(.left), right: value(.right), up: value(.up), down: value(.down))))
    }
}

struct CameraBodySettingsView: View {
    @ObservedObject var library: CameraBodyLibrary = .shared
    @State private var selectedID = PanoramaCameraBody.alpa12Max.id
    @State private var editing: CameraBodyDraft?
    @State private var deleting: PanoramaCameraBody?
    @State private var error: String?
    private var selected: PanoramaCameraBody { library.bodies.first { $0.id == selectedID } ?? .alpa12Max }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Picker(L10n.tr("ee38b80c37d9"), selection: $selectedID) {
                    Section(L10n.tr("cameraBodies.builtIn")) {
                        ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0.id) }
                    }
                    if !library.custom.isEmpty {
                        Section(L10n.tr("cameraBodies.custom")) {
                            ForEach(library.custom) { Text($0.name).tag($0.id) }
                        }
                    }
                }.accessibilityIdentifier("settings.cameraBodies.selection")
                Button(L10n.tr("cameraBodies.new")) { editing = CameraBodyDraft() }
                    .accessibilityIdentifier("settings.cameraBodies.new")
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selected.name).font(.headline).textSelection(.enabled)
                    Spacer()
                    Label(L10n.tr(selected.isBuiltIn ? "cameraBodies.builtIn" : "cameraBodies.custom"),
                          systemImage: selected.isBuiltIn ? "lock.fill" : "person.crop.square")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L10n.tr(selected.isBuiltIn ? "cameraBodies.builtInReadOnly" : "cameraBodies.customHint"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(CameraShiftDirection.allCases) { direction in
                    LabeledContent(direction.title) {
                        let amount = direction.amount(in: selected.defaultTravel)
                        Text(amount > 0 ? "\(amount.formatted(.number.precision(.fractionLength(0...2)))) mm" : L10n.tr("cameraBodies.noTravel"))
                            .monospacedDigit()
                    }
                }
                Text(L10n.tr("cameraBodies.coordinates"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button(L10n.tr("cameraBodies.edit")) {
                    if case .custom(let profile) = selected { editing = CameraBodyDraft(profile: profile) }
                }.disabled(selected.isBuiltIn).accessibilityIdentifier("settings.cameraBodies.edit")
                Button(L10n.tr("cameraBodies.delete"), role: .destructive) { deleting = selected }
                    .disabled(selected.isBuiltIn).accessibilityIdentifier("settings.cameraBodies.delete")
                Spacer()
            }
            if !library.issues.isEmpty {
                Text(library.issues.joined(separator: "\n")).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { library.refresh() }
        .sheet(item: $editing) { draft in
            CameraBodyEditor(draft: draft, library: library) { body in selectedID = body.id }
        }
        .alert(L10n.tr("cameraBodies.deleteQuestion"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L10n.tr("cameraBodies.cancel"), role: .cancel) { deleting = nil }
            Button(L10n.tr("cameraBodies.delete"), role: .destructive) {
                if let body = deleting {
                    do { try library.delete(body); selectedID = PanoramaCameraBody.alpa12Max.id }
                    catch { self.error = error.localizedDescription }
                }
                deleting = nil
            }
        } message: { Text(L10n.tr("cameraBodies.deleteHint")) }
        .alert(L10n.tr("cameraBodies.title"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L10n.tr("slices.ok")) { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct CameraBodyEditor: View {
    @State var draft: CameraBodyDraft
    @ObservedObject var library: CameraBodyLibrary
    let saved: (PanoramaCameraBody) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr(draft.isNew ? "cameraBodies.newTitle" : "cameraBodies.editTitle")).font(.title2.bold())
            TextField(L10n.tr("cameraBodies.name"), text: $draft.name)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("cameraBody.name")
            Text(L10n.tr("cameraBodies.directionsHint")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(CameraShiftDirection.allCases) { direction in
                HStack {
                    Toggle(direction.title, isOn: Binding(get: { draft.enabled.contains(direction) }, set: { enabled in
                        if enabled { draft.enabled.insert(direction) } else { draft.enabled.remove(direction) }
                    })).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("cameraBody.\(direction.rawValue).enabled")
                    TextField("0", value: Binding(get: { draft.amounts[direction] ?? 0 }, set: { draft.amounts[direction] = $0 }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 90)
                        .disabled(!draft.enabled.contains(direction))
                        .accessibilityIdentifier("cameraBody.\(direction.rawValue).amount")
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            Text(L10n.tr("cameraBodies.coordinates")).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L10n.tr("cameraBodies.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.tr("cameraBodies.save")) {
                    do { let body = try draft.body(); try library.save(body); saved(body); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cameraBody.save")
            }
        }.padding(24).frame(width: 400)
    }
}
