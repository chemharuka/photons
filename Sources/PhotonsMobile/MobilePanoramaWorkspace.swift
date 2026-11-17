#if os(iOS)
import SwiftUI
import PhotonsCore
import PhotonsPanorama

/// Physical right/up coordinates are independent of screen size and source pixel dimensions.
enum MobileShiftGeometry {
    static func dragged(_ start: CGPoint, translation: CGSize, pointsPerMM: Double, travel: PanoramaShiftRange) -> CGPoint {
        guard pointsPerMM.isFinite, pointsPerMM > 0 else { return start }
        return CGPoint(x: min(travel.right, max(-travel.left, start.x + translation.width / pointsPerMM)),
                       y: min(travel.up, max(-travel.down, start.y - translation.height / pointsPerMM)))
    }
}

/// The last successfully applied physical layout. Selection alone does not invalidate alignment.
struct MobilePanoramaLayout: Equatable {
    var positions: [Int: CGPoint]
    var body: PanoramaCameraBody
    var orientation: PanoramaBodyOrientation
    var sensorWidth: Double
    var sensorHeight: Double
    var manualSensor: Bool
    var guided: Bool
}

/// Choosing a capture model is required before registration starts.
struct MobilePanoramaFlow: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: PanoramaRegistrationMode?
    var body: some View {
        Group {
            if let mode { MobilePanoramaWorkspace(model: model, mode: mode) }
            else {
                NavigationStack {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("How were these photographs captured?").font(.largeTitle.weight(.semibold))
                        Text("Choose a stitching method before alignment starts.").foregroundStyle(.secondary)
                        choice(.shift, title: "Shift panorama", icon: "arrow.up.and.down.and.arrow.left.and.right", detail: "Lens or back movements on a shift camera. Includes body travel, draggable sensor positions and lens-profile LCC.")
                        choice(.perspective, title: "Perspective panorama", icon: "perspective", detail: "Overlapping views captured by rotating or tilting the camera. Aligns image features using perspective transforms.")
                        Spacer()
                    }.frame(maxWidth: 760).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.075)).navigationTitle("Panorama").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                }
            }
        }.preferredColorScheme(.dark).tint(.orange)
    }
    private func choice(_ value: PanoramaRegistrationMode, title: String, icon: String, detail: String) -> some View {
        Button { mode = value } label: {
            HStack(spacing: 20) {
                Image(systemName: icon).font(.largeTitle).frame(width: 64)
                VStack(alignment: .leading, spacing: 8) { Text(title).font(.title2.weight(.semibold)); Text(detail).font(.body).foregroundStyle(.secondary) }
                Spacer(); Image(systemName: "chevron.right")
            }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain).accessibilityIdentifier("choose-panorama-\(value.rawValue)")
    }
}

struct MobilePanoramaWorkspace: View {
    @ObservedObject var model: MobileWorkspaceModel
    @Environment(\.dismiss) private var dismiss
    private let photos: [MobilePhoto]
    private let mode: PanoramaRegistrationMode
    @State private var sources: [PanoramaSource] = []
    @State private var positions: [Int: CGPoint] = [:]
    @State private var selectedFrame = 0
    @State private var bodyType = PanoramaCameraBody.alpa12Max
    @State private var orientation = PanoramaBodyOrientation.degrees0
    @State private var options = PanoramaOptions()
    @State private var sensorWidth = 43.8
    @State private var sensorHeight = 32.9
    @State private var manualSensor = false
    @State private var guided = false
    @State private var appliedLayout: MobilePanoramaLayout?
    @State private var appliedOptions: PanoramaOptions?
    @State private var appliedSelection = 0
    @State private var aligning = false
    @State private var export = false
    @State private var profileID: UUID?
    @State private var cropToLCC = false
    private var layout: MobilePanoramaLayout {
        .init(positions: positions, body: bodyType, orientation: orientation, sensorWidth: sensorWidth,
              sensorHeight: sensorHeight, manualSensor: manualSensor, guided: guided)
    }
    private var dirty: Bool { appliedLayout != layout || appliedOptions != options }
    private var cropNeedsUpdate: Bool { cropToLCC != (model.plan?.lccState?.cropRect != nil) }
    private var sensor: SensorSize { .init(width: sensorWidth, height: sensorHeight, source: manualSensor ? "Manual" : "Source metadata") }
    private var validSensor: Bool { sensorWidth.isFinite && sensorHeight.isFinite && sensorWidth > 0 && sensorHeight > 0 && sensorWidth < 200 && sensorHeight < 200 }

    init(model: MobileWorkspaceModel, mode: PanoramaRegistrationMode) { self.model = model; self.mode = mode; photos = model.selectedPhotos }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    if model.busy {
                        HStack {
                            if let fraction = model.progress { ProgressView(value: fraction).frame(width: 130) } else { ProgressView() }
                            Text(model.status).font(.caption).lineLimit(1); Spacer()
                            Button("Cancel task") { model.cancel() }
                        }.padding(12)
                    }
                    if geometry.size.width >= 750 {
                        HStack(spacing: 0) { preview; Divider(); controls.frame(width: 340) }
                    } else {
                        VStack(spacing: 0) { preview.frame(height: geometry.size.height * 0.42); Divider(); controls }
                    }
                    Divider()
                    HStack {
                        if let plan = model.plan { Text("\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height)) · \(photos.count) photographs").font(.caption) }
                        Spacer()
                        Button("Stitch / Export") { export = true }
                            .buttonStyle(.borderedProminent).disabled(model.plan == nil || dirty || model.busy || cropNeedsUpdate)
                            .accessibilityIdentifier("panorama-export")
                    }.padding(14)
                }.background(Color(white: 0.075))
            }
            .navigationTitle(mode == .shift ? "Shift panorama" : "Perspective panorama").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { if model.busy { model.cancel() }; dismiss() }.accessibilityIdentifier("close-panorama")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(model.hdr ? "HDR" : "SDR") { model.toggleHDR() }.disabled(model.busy).accessibilityIdentifier("panorama-display-mode")
                }
            }
        }.preferredColorScheme(.dark).tint(.orange)
        .task {
            model.plan = nil; model.manifest = nil; model.frame = nil; model.error = nil
            do {
                sources = try await model.engine.sourceInfo(photos)
                if let known = sources.first?.sensor { sensorWidth = known.width; sensorHeight = known.height }
                else { manualSensor = true }
                positions = Dictionary(uniqueKeysWithValues: photos.indices.map { ($0, CGPoint.zero) })
                profileID = model.profiles.first?.id
                align()
            } catch { model.error = error.localizedDescription }
        }
        .onChange(of: model.busy) { _,busy in
            if !busy {
                if aligning {
                    aligning = false
                    if model.error == nil, let plan = model.plan { accept(plan) }
                } else if !dirty, model.error == nil, let plan = model.plan, let lcc = plan.lccState {
                    positions = framePositions(plan, offset: lcc.offsetMM)
                    rememberLayout()
                }
            }
        }
        .sheet(isPresented: $export) {
            NavigationStack {
                MobileExportSheet(model: model, onExport: { dismiss() })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { export = false } } }
            }.preferredColorScheme(.dark)
        }
        .alert("Panorama", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var preview: some View {
        ZStack {
            Color(white: 0.055)
            if model.plan != nil, let image = model.frame?.image {
                MobilePhotoCanvas(image: image, hdr: model.hdr, identity: "panorama-workspace")
                    .padding(20).accessibilityIdentifier("panorama-preview")
                if dirty { Text("Positions changed · update alignment to refresh this preview").font(.caption).padding(12).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding() }
            } else {
                ContentUnavailableView("Panorama preview", systemImage: "pano", description: Text(model.busy ? "Aligning the selected photographs…" : "Drag the source frames or enter measured positions, then update alignment."))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .shift {
                Text("SHIFT PANORAMA").font(.headline)
                Picker("Camera body", selection: $bodyType) { ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) } }
                MobileBodyOrientationPicker(cameraBody: bodyType, selection: $orientation)
                Text(bodyType.travel(at: orientation).summary).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Layout").font(.caption.weight(.semibold))
                    Spacer()
                    Button("Revert", action: revertLayout).buttonStyle(.bordered)
                        .disabled(appliedLayout == nil || appliedLayout == layout)
                        .accessibilityHint("Restore the last successfully aligned layout without running alignment again")
                        .accessibilityIdentifier("revert-panorama-layout")
                }
                if validSensor {
                    MobileDraggablePositions(names: photos.map(\.name), sensor: sensor, travel: bodyType.travel(at: orientation),
                        positions: $positions, selected: $selectedFrame, changed: { guided = true })
                        .frame(height: 310)
                }
                Text("Dashed outline: total sensor travel. Cross: body zero. Drag a frame to set an approximate position; update alignment to verify the overlap.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(photos.enumerated()), id: \.offset) { i,photo in
                    Button { selectedFrame = i } label: {
                        HStack {
                            if let image = model.thumbnails[photo.id]?.image { MobileThumbnail(image: image,hdr: model.hdr).frame(width: 42, height: 40) }
                            VStack(alignment: .leading) {
                                Text(photo.name).font(.caption.weight(.semibold))
                                let point = positions[i] ?? .zero
                                Text(String(format: "X %+.1f · Y %+.1f mm", point.x, point.y)).font(.caption.monospacedDigit())
                            }
                            Spacer(); if selectedFrame == i { Image(systemName: "checkmark.circle.fill") }
                        }.padding(8).background(selectedFrame == i ? Color.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("select-frame-\(i)")
                }
                if photos.indices.contains(selectedFrame) {
                    Text("Selected frame position").font(.caption.weight(.semibold))
                    MobilePositionFields(position: Binding(get: { positions[selectedFrame] ?? .zero }, set: { positions[selectedFrame] = $0; guided = true }))
                }
                Toggle("Use position guidance", isOn: $guided).accessibilityIdentifier("position-guidance")
                Text(guided ? "Positions guide matching near your measurements; image features still determine the final alignment." : "Automatic alignment shows relative positions; the absolute optical center has not been confirmed.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("PERSPECTIVE PANORAMA").font(.headline)
                    if let plan = model.plan { MobilePositionDiagram(plan: plan).frame(height: 280) }
                    Text("Image features determine the perspective alignment. This preview uses a planar projection; very wide or 360° panoramas are not yet supported.").font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("Alignment options") {
                    if mode == .shift {
                    Toggle("Override sensor dimensions", isOn: $manualSensor).onChange(of: manualSensor) { _,enabled in
                        if !enabled, let known = sources.first?.sensor { sensorWidth = known.width; sensorHeight = known.height }
                    }
                    if manualSensor {
                        LabeledContent("Width (mm)") { TextField("Width", value: $sensorWidth, format: .number) }
                        LabeledContent("Height (mm)") { TextField("Height", value: $sensorHeight, format: .number) }
                    } else { Text(String(format: "%.2f × %.2f mm", sensorWidth, sensorHeight)).font(.caption) }
                    }
                    Toggle("Match exposure", isOn: $options.matchExposure)
                    Toggle("Avoid moving subjects", isOn: $options.avoidMotion)
                    Slider(value: $options.seamSoftness, in: 0...20) { Text("Seam softness") }
                }
                Button("Update alignment", action: align).buttonStyle(.borderedProminent)
                    .disabled(model.busy || !validSensor || sources.count < 2).accessibilityIdentifier("align-panorama")
                Divider()
                if mode == .shift {
                Text("LCC CORRECTION").font(.caption.weight(.semibold))
                Picker("Lens profile", selection: $profileID) {
                    Text("Choose a profile").tag(UUID?.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle("Crop to corrected area", isOn: $cropToLCC).toggleStyle(MobileCheckboxStyle())
                    .accessibilityIdentifier("panorama-crop-lcc")
                    .disabled(model.plan?.lccState.map { $0.suggestedCropRect == nil && !cropToLCC } ?? false)
                    .onChange(of: cropToLCC) { _,enabled in
                        if model.plan?.lccState != nil && !dirty { model.setLCCCrop(enabled) }
                    }
                Text("Keeps the largest rectangle fully covered by the lens calibration.").font(.caption).foregroundStyle(.secondary)
                Button("Apply lens profile") {
                    guard let profileID, let plan = model.plan else { return }
                    let offset = guided ? PanoramaPositionReference(sourceIndex: selectedFrame, positionMM: positions[selectedFrame] ?? .zero).profileOffset(in: plan, sensor: sensor) : nil
                    model.correctPanorama(profileID: profileID, offset: offset, body: bodyType, orientation: orientation, cropToCoverage: cropToLCC)
                }.disabled(model.busy || dirty || model.plan == nil || profileID == nil).accessibilityIdentifier("panorama-lcc")
                if let lcc = model.plan?.lccState { Label(lcc.profileName, systemImage: "checkmark.seal"); Text(String(format: "Coverage %.1f%%", lcc.coveredFraction * 100)).font(.caption) }
                if let note = model.lccPositionNote { Text(note).font(.caption).foregroundStyle(.orange) }
                } else { Text(PanoramaRegistrationMode.perspectiveLCCNotice).font(.caption).foregroundStyle(.secondary) }
                if let histogram = model.frame?.histogram { MobileHistogram(histogram: histogram).frame(height: 100) }
            }.padding(18).disabled(model.busy)
        }.background(Color(white: 0.105)).accessibilityIdentifier("panorama-controls")
    }
    private func align() {
        guard validSensor, !model.busy else { return }
        aligning = true; model.error = nil
        model.stitch(options: options, positions: mode == .shift && guided ? positions : [:], sensor: mode == .shift && manualSensor ? sensor : nil, registrationMode: mode)
    }
    private func accept(_ plan: PanoramaPlan) {
        let anchor = mode == .shift && guided ? PanoramaPositionReference(sourceIndex: selectedFrame, positionMM: positions[selectedFrame] ?? .zero) : nil
        let offset = anchor?.profileOffset(in: plan, sensor: sensor) ?? .zero
        positions = framePositions(plan, offset: offset)
        // Measured absolute reference survives an uncorrected export for later LCC.
        if anchor != nil { model.manifest = PanoramaManifest(plan: plan, offsetMM: offset, sensor: sensor, bodyOrientation: orientation, cameraBody: bodyType) }
        rememberLayout()
    }
    private func rememberLayout() {
        appliedLayout = layout; appliedOptions = options; appliedSelection = selectedFrame
    }
    private func revertLayout() {
        guard let saved = appliedLayout, !model.busy else { return }
        positions = saved.positions; bodyType = saved.body; orientation = saved.orientation
        sensorWidth = saved.sensorWidth; sensorHeight = saved.sensorHeight; manualSensor = saved.manualSensor
        guided = saved.guided; selectedFrame = appliedSelection
        model.error = nil
        // Pending alignment options still invalidate the preview; Revert only restores the layout.
    }
    private func framePositions(_ plan: PanoramaPlan, offset: CGPoint) -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: plan.sources.indices.map { i in
            let r = plan.sensorRect(i)
            return (i, CGPoint(x: (r.midX - plan.size.width / 2) * sensor.width / r.width - offset.x,
                               y: (plan.size.height / 2 - r.midY) * sensor.height / r.height - offset.y))
        })
    }
}

struct MobileDraggablePositions: View {
    let names: [String]
    let sensor: SensorSize
    let travel: PanoramaShiftRange
    @Binding var positions: [Int: CGPoint]
    @Binding var selected: Int
    let changed: () -> Void
    @Namespace private var canvasSpace
    var body: some View {
        GeometryReader { geometry in
            let bounds = travel.coverage(sensor: sensor, centered: false).insetBy(dx: -4, dy: -4)
            let scale = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let x0 = (geometry.size.width - bounds.width * scale) / 2 - bounds.minX * scale
            let y0 = (geometry.size.height - bounds.height * scale) / 2 - bounds.minY * scale
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.2)
                let coverage = travel.coverage(sensor: sensor, centered: false)
                Rectangle().stroke(.gray, style: StrokeStyle(lineWidth: 1, dash: [5,4]))
                    .frame(width: coverage.width * scale, height: coverage.height * scale)
                    .offset(x: x0 + coverage.minX * scale, y: y0 + coverage.minY * scale)
                Rectangle().stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2,3]))
                    .frame(width: sensor.width * scale, height: sensor.height * scale)
                    .offset(x: x0 - sensor.width * scale / 2, y: y0 - sensor.height * scale / 2)
                Image(systemName: "plus").font(.caption).position(x: x0, y: y0)
                ForEach(names.indices, id: \.self) { i in
                    MobileDraggableFrame(name: names[i], index: i, sensor: sensor, travel: travel,
                        position: Binding(get: { positions[i] ?? .zero }, set: { positions[i] = $0 }),
                        selected: $selected, scale: scale, zero: CGPoint(x: x0, y: y0),
                        coordinateSpace: canvasSpace, changed: changed)
                        .zIndex(selected == i ? 2 : 1)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .coordinateSpace(name: canvasSpace).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityElement(children: .contain).accessibilityIdentifier("body-shift-diagram")
    }
}
/// Keep the stored center fixed during a drag. GestureState resets on completion AND cancellation.
private struct MobileDraggableFrame: View {
    let name: String
    let index: Int
    let sensor: SensorSize
    let travel: PanoramaShiftRange
    @Binding var position: CGPoint
    @Binding var selected: Int
    let scale: Double
    let zero: CGPoint
    let coordinateSpace: Namespace.ID
    let changed: () -> Void
    @GestureState private var translation = CGSize.zero

    var body: some View {
        let center = translation == .zero ? position : MobileShiftGeometry.dragged(position, translation: translation, pointsPerMM: scale, travel: travel)
        let color = travel.contains(center, tolerance: 0.1) ? [Color.cyan, .purple, .green, .pink][index % 4] : .orange
        Rectangle().fill(color.opacity(selected == index ? 0.25 : 0.1))
            .overlay(Rectangle().stroke(color, lineWidth: selected == index ? 2.5 : 1))
            .overlay(Text(name).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.5).padding(4), alignment: .top)
            .overlay {
                if selected == index { Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(color).accessibilityHidden(true) }
            }
            .frame(width: sensor.width * scale, height: sensor.height * scale)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(coordinateSpace))
                .updating($translation) { value, state, transaction in
                    transaction.animation = nil
                    state = value.translation
                }
                .onChanged { _ in selected = index }
                .onEnded { value in
                    let moved = MobileShiftGeometry.dragged(position, translation: value.translation, pointsPerMM: scale, travel: travel)
                    if moved != position { position = moved; changed() }
                })
            .onTapGesture { selected = index }
            .position(x: zero.x + center.x * scale, y: zero.y - center.y * scale)
            .accessibilityElement(children: .ignore).accessibilityLabel(name)
            .accessibilityAddTraits(.isButton).accessibilityAction { selected = index }
            .accessibilityValue(String(format: "X %.1f, Y %.1f millimeters", center.x, center.y))
            .accessibilityIdentifier("shift-frame-\(index)")
    }
}

#endif
