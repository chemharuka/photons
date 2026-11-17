#if os(iOS)
import SwiftUI
import PhotonsLocalization
import UniformTypeIdentifiers
import PhotonsCore
import PhotonsPanorama

struct MobileLCCSheet: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var traditional = false
    @State private var flat: URL?
    @State private var flatPicker = false
    @State private var profileID: UUID?
    @State private var manual = false
    @State private var position = CGPoint.zero
    @State private var reference = -1
    @State private var refine = true
    @State private var bodyType = PanoramaCameraBody.alpa12Max
    @State private var orientation = PanoramaBodyOrientation.degrees0
    @State private var cropToLCC = false
    private var panorama: PanoramaPlan? { model.plan.flatMap { $0.sources.count > 1 ? $0 : nil } }
    var body: some View {
        Form {
            Section(L10n.tr("ipad.ecfd2c203987")) {
                Picker(L10n.tr("ipad.52a0f9b65b27"), selection: $traditional) {
                    Text(L10n.tr("5c30b533510f")).tag(false)
                    if panorama == nil { Text(L10n.tr("ipad.034223f5e897")).tag(true) }
                }.pickerStyle(.segmented)
                if traditional {
                    Button(flat?.lastPathComponent ?? L10n.tr("ipad.0e482b24c61f")) { flatPicker = true }
                    Text(L10n.tr("ipad.2a748956e4a0")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker(L10n.tr("5c30b533510f"), selection: $profileID) {
                        Text(L10n.tr("ipad.416c3478ef2c")).tag(UUID?.none)
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker(L10n.tr("ee38b80c37d9"), selection: $bodyType) { ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) } }
                    MobileBodyOrientationPicker(cameraBody: bodyType, selection: $orientation)
                    if panorama != nil {
                        Toggle(L10n.tr("ipad.2c1f86e2653a"), isOn: $cropToLCC).toggleStyle(MobileCheckboxStyle()).accessibilityIdentifier("lcc-crop-coverage")
                    }
                    Toggle(L10n.tr("ipad.866dd753c78b"), isOn: $manual)
                    if manual {
                        if let plan = panorama {
                            Picker(L10n.tr("lcc.position.reference"), selection: $reference) {
                                Text(L10n.tr("ipad.af6d15f68a25")).tag(-1)
                                ForEach(Array(plan.sources.enumerated()), id: \.offset) { i,source in Text(source.url.lastPathComponent).tag(i) }
                            }
                        }
                        MobilePositionFields(position: $position)
                        if panorama == nil { Toggle(L10n.tr("ipad.22563b53a721"), isOn: $refine) }
                    }
                    Text(L10n.tr("ipad.3792ce8c11f1")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let plan = panorama { Section(L10n.tr("ipad.d381b5a2772c")) { MobilePositionDiagram(plan: plan).frame(height: 260) } }
            Section {
                Button(L10n.tr("ipad.01e027a09783")) {
                    if let plan = panorama, let profileID {
                        var offset: CGPoint?
                        if manual {
                            if reference >= 0, let sensor = plan.sources[reference].sensor {
                                offset = PanoramaPositionReference(sourceIndex: reference, positionMM: position).profileOffset(in: plan, sensor: sensor)
                            } else { offset = CGPoint(x: -position.x, y: -position.y) }
                        }
                        model.correctPanorama(profileID: profileID, offset: offset, body: bodyType, orientation: orientation, cropToCoverage: cropToLCC)
                    } else {
                        model.correct(flat: traditional ? flat : nil, profileID: profileID,
                            position: manual ? position : nil, refine: refine, body: bodyType, orientation: orientation)
                    }
                    dismiss()
                }.disabled(traditional ? flat == nil : profileID == nil).accessibilityIdentifier("solve-lcc")
            } footer: {
                Text(L10n.tr("ipad.a304e0f5b8e8"))
            }
        }.navigationTitle(L10n.tr("ipad.40c527f3f714"))
            .onAppear { profileID = model.profiles.first?.id; cropToLCC = panorama?.lccState?.cropRect != nil }
            .fileImporter(isPresented: $flatPicker, allowedContentTypes: [.rawImage]) { result in
                do { flat = try result.get() } catch { model.error = error.localizedDescription }
            }
    }
}
struct MobilePositionFields: View {
    @Binding var position: CGPoint
    var body: some View {
        HStack {
            Text("X").foregroundStyle(.secondary)
            TextField("X", value: Binding<Double>(get: { Double(position.x) }, set: { position.x = CGFloat($0) }), format: .number.precision(.fractionLength(0...2))).keyboardType(.numbersAndPunctuation)
            Text("Y").foregroundStyle(.secondary)
            TextField("Y", value: Binding<Double>(get: { Double(position.y) }, set: { position.y = CGFloat($0) }), format: .number.precision(.fractionLength(0...2))).keyboardType(.numbersAndPunctuation)
            Text("mm").foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
    }
}
struct MobileProfilesSheet: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var importer = false
    @State private var creating = false
    @State private var name = L10n.tr("ipad.16e850a2bbae")
    @State private var frames: [LCCCreationFrame] = []
    @State private var sensorWidth = 43.8
    @State private var sensorHeight = 32.9
    var body: some View {
        Form {
            Section(L10n.tr("ipad.441d4af6ac66")) {
                ForEach(model.profiles) { profile in
                    NavigationLink {
                        MobileProfileDetails(engine: model.engine,id: profile.id)
                    } label: {
                        VStack(alignment: .leading,spacing: 4) {
                            Text(profile.name)
                            Text(profile.camera).font(.caption).foregroundStyle(.secondary)
                            Text(L10n.tr("ipad.fea6d2b29f66", String(describing: (profile.captureCount)), String(describing: (profile.variants.count)))).font(.caption)
                        }
                    }.accessibilityIdentifier("lens-profile-\(profile.id.uuidString)")
                }
                Button(L10n.tr("ipad.456d8498f8b7")) { importer = true }
            }
            Section(L10n.tr("ipad.dbee444b0470")) {
                Text(L10n.tr("ipad.bf994aee8e7e")).font(.caption)
                if !creating {
                    Button(L10n.tr("ipad.499f4ce1b25d", String(describing: (model.selected.count)))) {
                        let urls = model.selectedPhotos.map(\.url)
                        Task {
                            do {
                                frames = try await Task.detached { try urls.map { try LCCCreationFrame(url: $0) } }.value
                                if let sensor = frames.first?.source.sensor { sensorWidth = sensor.width; sensorHeight = sensor.height }
                                creating = true
                            } catch { model.error = error.localizedDescription }
                        }
                    }.disabled(model.selected.isEmpty)
                } else {
                    TextField(L10n.tr("ipad.d3663280e101"), text: $name)
                    LabeledContent(L10n.tr("ipad.4196e68453f4")) { TextField(L10n.tr("ipad.3019947b6daf"), value: $sensorWidth, format: .number) }
                    LabeledContent(L10n.tr("ipad.6e9c2ba66c65")) { TextField(L10n.tr("ipad.bfe2eca40179"), value: $sensorHeight, format: .number) }
                    ForEach(frames.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(frames[i].source.url.lastPathComponent)
                            MobilePositionFields(position: Binding(get: { CGPoint(x: frames[i].shiftX, y: frames[i].shiftY) }, set: { frames[i].shiftX = $0.x; frames[i].shiftY = $0.y }))
                            Toggle(L10n.tr("ipad.77155e96c8eb"), isOn: $frames[i].shiftConfirmed)
                        }
                    }
                    Button(L10n.tr("ipad.61d30d997d13")) {
                        model.createProfile(name: name, frames: frames,
                            sensor: SensorSize(width: sensorWidth, height: sensorHeight, source: "Manual")); dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !frames.allSatisfy(\.shiftConfirmed))
                }
            }
        }.navigationTitle(L10n.tr("ipad.bf744e98a728"))
            .fileImporter(isPresented: $importer, allowedContentTypes: [UTType(filenameExtension: "photonslcc") ?? .data]) { result in
                do { model.importProfile(try result.get()); dismiss() } catch { model.error = error.localizedDescription }
            }
    }
}
struct MobileExportSheet: View {
    @ObservedObject var model: MobileWorkspaceModel
    var onExport: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var settings = MobileExportSettings()
    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("ipad.ceab5645f7ee"), selection: $settings.hdr) { Text("HDR").tag(true); Text("SDR").tag(false) }.pickerStyle(.segmented)
                    .onChange(of: settings.hdr) { _,hdr in if !hdr && settings.format == "dng" { settings.format = "tiff" } }
                Picker(L10n.tr("0e8b1c78c5f3"), selection: $settings.format) {
                    ForEach(settings.hdr ? ["heic", "jpeg", "tiff", "png", "dng"] : ["jpeg", "heic", "tiff", "png"], id: \.self) {
                        Text($0 == "dng" ? L10n.tr("ipad.d593198f3a9f") : $0.uppercased()).tag($0)
                    }
                }
                Picker(L10n.tr("dc4ffb23c9a3"), selection: $settings.longEdge) {
                    Text(L10n.tr("ipad.961306829a55")).tag(0)
                    Text(L10n.tr("ipad.650d29374447")).tag(2048); Text(L10n.tr("ipad.a4cc512bd538")).tag(4096); Text(L10n.tr("ipad.f702ee55003d")).tag(6000)
                }.accessibilityIdentifier("export-size")
                if settings.longEdge == 0, let size = model.plan?.outputSize {
                    Text(L10n.tr("ipad.e637f11069bb", String(describing: (Int(size.width))), String(describing: (Int(size.height))))).font(.caption).foregroundStyle(.secondary)
                }
                if settings.format == "jpeg" || settings.format == "heic" { Slider(value: $settings.quality, in: 0.5...1) { Text(L10n.tr("55847d2e5bed")) } }
            } footer: { Text(L10n.tr("ipad.112c02e83fc1")) }
            Section {
                Text(L10n.tr("ipad.d153ac56fa98"))
                Button(L10n.tr("ipad.bf930788929a")) { model.export(settings); dismiss(); onExport() }.accessibilityIdentifier("confirm-export")
            }
        }.navigationTitle(L10n.tr("76420433f22d")).onAppear { settings.hdr = model.hdr }
    }
}
struct MobileSettingsView: View {
    var libraryOnly = false
    @ObservedObject var model: MobileWorkspaceModel
    @AppStorage("photons.mobile.skipDuplicates") private var skipDuplicates = true
    @AppStorage("photons.historyDepth") private var historyDepth = 20
    @AppStorage("photons.language") private var language = L10n.defaultLanguage
    var body: some View {
        Form {
            if !libraryOnly { Section(L10n.tr("cameraBodies.generalTab")) {
                Picker(L10n.tr("9f6fee1aba17"),selection: $language) { Text("English").tag("en"); Text("简体中文").tag("zh-Hans") }
                    .accessibilityIdentifier("interface-language")
                Text(L10n.tr("ipad.c13332b27e49")).font(.caption).foregroundStyle(.secondary)
            } }
            if libraryOnly { Section(L10n.tr("ipad.dc20b3d5d2cd")) {
                LabeledContent(L10n.tr("ipad.dc20b3d5d2cd"), value: L10n.tr("ipad.a55b98326758"))
                LabeledContent(L10n.tr("ipad.6313ce0c3805"), value: "\(model.photos.count)")
                Toggle(L10n.tr("ipad.d93000bd52a0"), isOn: $skipDuplicates)
                Text(L10n.tr("ipad.0c69ad7b242b")).font(.caption).foregroundStyle(.secondary)
            }
            } else {
            Section(L10n.tr("ipad.fab4539d26e0")) {
                Picker(L10n.tr("settings.historyDepth"), selection: $historyDepth) { ForEach([10,20,50,100], id: \.self) { Text("\($0)").tag($0) } }
                Text(L10n.tr("ipad.44b0de3df4ee")).font(.caption).foregroundStyle(.secondary)
                Toggle(L10n.tr("ipad.cfdca5c797a2"), isOn: Binding(get: { model.hdr }, set: { if $0 != model.hdr { model.toggleHDR() } }))
                LabeledContent(L10n.tr("ipad.renderingBackend"), value: "Metal GPU")
            }
            Section(L10n.tr("ipad.78f0c369e5d9")) { Text(L10n.tr("ipad.51e00fe1586d")) }
            }
            MobileCacheSettings(model: model)
        }.navigationTitle(libraryOnly ? L10n.tr("ipad.260a1e306790") : L10n.tr("cameraBodies.generalTab"))
    }
}
struct MobileCapabilitiesView: View {
    var body: some View {
        List {
            Section(L10n.tr("ipad.55b316feaef9")) {
                ForEach([L10n.tr("ipad.c1ba68c57d4c"), L10n.tr("ipad.fe22a35e1b1c"), L10n.tr("ipad.6dc5f1a400a9"), L10n.tr("ipad.c1f6f488ea89"), L10n.tr("ipad.ac7e1ccf8554"), L10n.tr("ipad.e35913303306"), L10n.tr("ipad.39dc0ea10a0d"), L10n.tr("ipad.4b086f5834a2"), L10n.tr("ipad.de447aeacb20"), L10n.tr("ipad.ddc67faa51f3"), L10n.tr("ipad.d1c9377b9c59"), L10n.tr("ipad.3a75a6cf05ec"), L10n.tr("ipad.2ba0929fa987"), L10n.tr("ipad.d6e8a3aeecbd")], id: \.self) { Label($0, systemImage: "checkmark.circle") }
            }
            Section(L10n.tr("ipad.286c9246259e")) {
                ForEach([L10n.tr("ipad.9727fa56083a"), L10n.tr("ipad.69342490035c"), L10n.tr("ipad.7957a4a78ee1"), L10n.tr("ipad.4d7ece5cc8a2"), L10n.tr("ipad.6f4f713d2e26")], id: \.self) { Label($0, systemImage: "clock") }
            }
            Section { Text(L10n.tr("ipad.4fda75ebde27")) }
        }.navigationTitle(L10n.tr("ipad.ba7bc9604cf8"))
    }
}
#endif
