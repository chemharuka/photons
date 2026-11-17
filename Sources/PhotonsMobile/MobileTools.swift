#if os(iOS)
import SwiftUI
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
            Section("Correction method") {
                Picker("Method", selection: $traditional) {
                    Text("Lens profile").tag(false)
                    if panorama == nil { Text("Matching LCC frame").tag(true) }
                }.pickerStyle(.segmented)
                if traditional {
                    Button(flat?.lastPathComponent ?? "Choose matching LCC frame") { flatPicker = true }
                    Text("Use the flat-field frame captured at exactly the same camera and shift position.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Lens profile", selection: $profileID) {
                        Text("Choose a profile").tag(UUID?.none)
                        ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    Picker("Camera body", selection: $bodyType) { ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) } }
                    MobileBodyOrientationPicker(cameraBody: bodyType, selection: $orientation)
                    if panorama != nil {
                        Toggle("Crop to corrected area", isOn: $cropToLCC).toggleStyle(MobileCheckboxStyle()).accessibilityIdentifier("lcc-crop-coverage")
                    }
                    Toggle("Specify approximate position", isOn: $manual)
                    if manual {
                        if let plan = panorama {
                            Picker("Position reference", selection: $reference) {
                                Text("Panorama center").tag(-1)
                                ForEach(Array(plan.sources.enumerated()), id: \.offset) { i,source in Text(source.url.lastPathComponent).tag(i) }
                            }
                        }
                        MobilePositionFields(position: $position)
                        if panorama == nil { Toggle("Refine position automatically", isOn: $refine) }
                    }
                    Text("Right and up are positive. Leave manual position off to solve automatically.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let plan = panorama { Section("Source positions") { MobilePositionDiagram(plan: plan).frame(height: 260) } }
            Section {
                Button("Solve & preview correction") {
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
                Text("Reimported panoramas use their embedded source geometry. Rendered HEIC/TIFF correction can differ from RAW correction; applying LCC before stitching gives the closest match.")
            }
        }.navigationTitle("LCC correction")
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
    @State private var name = "My lens profile"
    @State private var frames: [LCCCreationFrame] = []
    @State private var sensorWidth = 43.8
    @State private var sensorHeight = 32.9
    var body: some View {
        Form {
            Section("Installed profiles") {
                ForEach(model.profiles) { profile in
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text(profile.camera).font(.caption).foregroundStyle(.secondary)
                        ShareLink(item: LCCProfileStore().url(for: profile.id)) { Text("Share profile") }.font(.caption)
                    }
                }
                Button("Import lens profile") { importer = true }
            }
            Section("Create from selected LCC photographs") {
                Text("Select calibration photographs in the library, then enter their measured shift positions here.").font(.caption)
                if !creating {
                    Button("Prepare \(model.selected.count) calibration frame(s)") {
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
                    TextField("Profile name", text: $name)
                    LabeledContent("Sensor width (mm)") { TextField("Width", value: $sensorWidth, format: .number) }
                    LabeledContent("Sensor height (mm)") { TextField("Height", value: $sensorHeight, format: .number) }
                    ForEach(frames.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(frames[i].source.url.lastPathComponent)
                            MobilePositionFields(position: Binding(get: { CGPoint(x: frames[i].shiftX, y: frames[i].shiftY) }, set: { frames[i].shiftX = $0.x; frames[i].shiftY = $0.y }))
                            Toggle("Position confirmed", isOn: $frames[i].shiftConfirmed)
                        }
                    }
                    Button("Create profile") {
                        model.createProfile(name: name, frames: frames,
                            sensor: SensorSize(width: sensorWidth, height: sensorHeight, source: "Manual")); dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || !frames.allSatisfy(\.shiftConfirmed))
                }
            }
        }.navigationTitle("Lens profiles")
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
                Picker("Output range", selection: $settings.hdr) { Text("HDR").tag(true); Text("SDR").tag(false) }.pickerStyle(.segmented)
                    .onChange(of: settings.hdr) { _,hdr in if !hdr && settings.format == "dng" { settings.format = "tiff" } }
                Picker("Format", selection: $settings.format) {
                    ForEach(settings.hdr ? ["heic", "jpeg", "tiff", "png", "dng"] : ["jpeg", "heic", "tiff", "png"], id: \.self) {
                        Text($0 == "dng" ? "16-bit lossless linear DNG" : $0.uppercased()).tag($0)
                    }
                }
                Picker("Long edge", selection: $settings.longEdge) {
                    Text("Full resolution").tag(0)
                    Text("2048 px").tag(2048); Text("4096 px").tag(4096); Text("6000 px").tag(6000)
                }.accessibilityIdentifier("export-size")
                if settings.longEdge == 0, let size = model.plan?.outputSize {
                    Text("\(Int(size.width)) × \(Int(size.height)) pixels").font(.caption).foregroundStyle(.secondary)
                }
                if settings.format == "jpeg" || settings.format == "heic" { Slider(value: $settings.quality, in: 0.5...1) { Text("Quality") } }
            } footer: { Text("Exports never upscale. Full resolution preserves the original output dimensions. Large images require enough available memory; if they do not fit, choose a smaller size.") }
            Section {
                Text("Output is saved in Photons Preview → Exports in Files and imported into this library. Use Save / Share afterwards to choose another location.")
                Button("Export image") { model.export(settings); dismiss(); onExport() }.accessibilityIdentifier("confirm-export")
            }
        }.navigationTitle("Export").onAppear { settings.hdr = model.hdr }
    }
}
struct MobileSettingsView: View {
    var libraryOnly = false
    @ObservedObject var model: MobileWorkspaceModel
    @AppStorage("photons.mobile.skipDuplicates") private var skipDuplicates = true
    @AppStorage("photons.historyDepth") private var historyDepth = 20
    var body: some View {
        Form {
            if !libraryOnly { Section("General") { LabeledContent("Language", value: "English · development preview") } }
            if libraryOnly { Section("Library") {
                LabeledContent("Library", value: "iPad Preview")
                LabeledContent("Photographs", value: "\(model.photos.count)")
                Toggle("Skip duplicate imports", isOn: $skipDuplicates)
                Text("Imported originals are copied into the app's Documents folder. The library is local to this iPad; cloud sync is not enabled.").font(.caption).foregroundStyle(.secondary)
            }
            } else {
            Section("Editing") {
                Picker("History length", selection: $historyDepth) { ForEach([10,20,50,100], id: \.self) { Text("\($0)").tag($0) } }
                Text("History length applies when the next photo is opened.").font(.caption).foregroundStyle(.secondary)
                Toggle("HDR preview", isOn: Binding(get: { model.hdr }, set: { if $0 != model.hdr { model.toggleHDR() } }))
                LabeledContent("Rendering", value: "Metal GPU")
            }
            Section("Development preview") { Text("The shared engines are running on iPadOS. Some desktop interfaces and external helpers are still being adapted. See Preview capabilities for the current scope.") }
            }
        }.navigationTitle(libraryOnly ? "Photo library" : "General")
    }
}
struct MobileCapabilitiesView: View {
    var body: some View {
        List {
            Section("Available in this preview") {
                ForEach(["Files import and persistent local library", "Duplicate control, ratings and thumbnail sizing", "Shared adjustment controls, HSL and color grading", "Crop coordinates, rotation, undo and reset", "HDR / SDR preview and cached histograms", "Panorama alignment and relative source positions", "Matching-frame and lens-profile LCC correction", "Lens-profile import, creation and sharing", "Post-export LCC using panorama metadata", "HDR / SDR export and lossless linear DNG"], id: \.self) { Label($0, systemImage: "checkmark.circle") }
            }
            Section("Next stages · not yet available") {
                ForEach(["Touch curve editor, masking and healing tools", "Full desktop preset and library management interfaces", "Social-media slicing and advanced batch export", "AI denoise and exposure-stack HDR helper replacement", "Resumable background processing", "Complete Chinese interface"], id: \.self) { Label($0, systemImage: "clock") }
            }
            Section { Text("Simulator tests validate integration, not physical-device RAW support, HDR display quality, memory limits or sustained thermals.") }
        }.navigationTitle("Preview capabilities")
    }
}
#endif
