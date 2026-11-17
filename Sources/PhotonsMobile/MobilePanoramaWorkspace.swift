#if os(iOS)
import PhotonsLocalization
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
                        Text(L10n.tr("ipad.5751afd037c5")).font(.largeTitle.weight(.semibold))
                        Text(L10n.tr("ipad.261d16b51159")).foregroundStyle(.secondary)
                        choice(.shift, title: L10n.tr("ipad.b71c15ebb55f"), icon: "arrow.up.and.down.and.arrow.left.and.right", detail: L10n.tr("ipad.02328ac07839"))
                        choice(.perspective, title: L10n.tr("ipad.7899ba345db2"), icon: "perspective", detail: L10n.tr("ipad.407b4cb69332"))
                        Spacer()
                    }.frame(maxWidth: 760).padding(36).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: 0.075)).navigationTitle(L10n.tr("ipad.2be61912014b")).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("3fd47edce45b")) { dismiss() } } }
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
                            Button(L10n.tr("ipad.a1d26b85bf20")) { model.cancel() }
                        }.padding(12)
                    }
                    if geometry.size.width >= 750 {
                        HStack(spacing: 0) { preview; Divider(); controls.frame(width: 340) }
                    } else {
                        VStack(spacing: 0) { preview.frame(height: geometry.size.height * 0.42); Divider(); controls }
                    }
                    Divider()
                    HStack {
                        if let plan = model.plan { Text(L10n.tr("ipad.373e02dc1d14", String(describing: (Int(plan.outputSize.width))), String(describing: (Int(plan.outputSize.height))), String(describing: (photos.count)))).font(.caption) }
                        Spacer()
                        Button(L10n.tr("ipad.157f52f85cb4")) { export = true }
                            .buttonStyle(.borderedProminent).disabled(model.plan == nil || dirty || model.busy || model.rendering || cropNeedsUpdate)
                            .accessibilityIdentifier("panorama-export")
                    }.padding(14)
                }.background(Color(white: 0.075))
            }
            .navigationTitle(mode == .shift ? L10n.tr("ipad.b71c15ebb55f") : L10n.tr("ipad.7899ba345db2")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("3fd47edce45b")) { if model.busy { model.cancel() }; dismiss() }.accessibilityIdentifier("close-panorama")
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
                try Task.checkCancellation()
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
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("3fd47edce45b")) { export = false } } }
            }.preferredColorScheme(.dark)
        }
        .alert(L10n.tr("ipad.2be61912014b"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L10n.tr("slices.ok")) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var preview: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.055)
                if model.plan != nil, let image = model.frame?.image {
                    MobilePhotoCanvas(image: image, hdr: model.hdr, identity: "panorama-workspace",accessibilityID: "panorama-preview",fullSize: model.canvasSize,
                                      detail: model.detailFrame,detailStatus: model.detailStatus,onViewportChange: { model.requestDetail($0) })
                        .padding(20)
                    if dirty { Text(L10n.tr("ipad.88fd9edaed0d")).font(.caption).padding(12).background(.ultraThinMaterial, in: Capsule()).frame(maxHeight: .infinity, alignment: .bottom).padding() }
                } else {
                    ContentUnavailableView(L10n.tr("slices.preview"), systemImage: "pano", description: Text(model.busy ? L10n.tr("ipad.25afb41e1b07") : L10n.tr("ipad.0d16cdbf4439")))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.plan?.isRegistered == true {
                Divider()
                VStack(spacing: 6) {
                    HStack(alignment: .center,spacing: 20) {
                        MobileSlider(title: L10n.tr("ipad.81aa08939843"),value: toneBinding(\.exposureEV),range: -4...4,step: 0.05,commit: {})
                            .accessibilityIdentifier("panorama-exposure")
                        MobileSlider(title: L10n.tr("panorama.tone.highlights"),value: Binding(get: {
                            log2(model.plan?.tone.highlightHeadroom ?? 4)
                        },set: { value in
                            var tone = model.plan?.tone ?? .panoramaDefault
                            tone.highlightHeadroom = pow(2,min(4,max(0,value.isFinite ? value : 2))); model.setPanoramaTone(tone)
                        }),range: 0...4,step: 0.1,commit: {}).accessibilityIdentifier("panorama-hdr-brightness")
                        Button(L10n.tr("panorama.tone.reset")) { model.setPanoramaTone(.panoramaDefault) }
                            .disabled(model.plan?.tone == .panoramaDefault).accessibilityIdentifier("reset-panorama-brightness")
                    }
                    Text(L10n.tr("panorama.tone.hint"))
                        .font(.caption2).foregroundStyle(.secondary)
                }.padding(12).background(.thinMaterial).disabled(model.busy)
            }
        }
    }
    private func toneBinding(_ path: WritableKeyPath<PanoramaToneSettings,Double>) -> Binding<Double> {
        Binding(get: { (model.plan?.tone ?? .panoramaDefault)[keyPath: path] },set: { value in
            var tone = model.plan?.tone ?? .panoramaDefault
            tone[keyPath: path] = min(4,max(-4,value.isFinite ? value : 0)); model.setPanoramaTone(tone)
        })
    }
    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if mode == .shift {
                Text(L10n.tr("ipad.1d5e10d2cfa8")).font(.headline)
                Picker(L10n.tr("ee38b80c37d9"), selection: $bodyType) { ForEach(PanoramaCameraBody.allCases) { Text($0.name).tag($0) } }
                MobileBodyOrientationPicker(cameraBody: bodyType, selection: $orientation)
                Text(bodyType.travel(at: orientation).summary).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(L10n.tr("ipad.a511909161e1")).font(.caption.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("ipad.0026c5053478"), action: revertLayout).buttonStyle(.bordered)
                        .disabled(appliedLayout == nil || appliedLayout == layout)
                        .accessibilityHint(L10n.tr("ipad.c6c279a60a1f"))
                        .accessibilityIdentifier("revert-panorama-layout")
                }
                if validSensor {
                    MobileDraggablePositions(names: photos.map(\.name), sensor: sensor, travel: bodyType.travel(at: orientation),
                        positions: $positions, selected: $selectedFrame, changed: { guided = true })
                        .frame(height: 310)
                }
                Text(L10n.tr("ipad.e8b944b7ea4c"))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(photos.enumerated()), id: \.offset) { i,photo in
                    Button { selectedFrame = i } label: {
                        HStack {
                            if let image = model.thumbnails[photo.id]?.image { MobileThumbnail(image: image,hdr: model.hdr).frame(width: 42, height: 40) }
                            VStack(alignment: .leading) {
                                Text(photo.name).font(.caption.weight(.semibold))
                                let point = positions[i] ?? .zero
                                Text(String(format: L10n.tr("ipad.9126f1282784"), point.x, point.y)).font(.caption.monospacedDigit())
                            }
                            Spacer(); if selectedFrame == i { Image(systemName: "checkmark.circle.fill") }
                        }.padding(8).background(selectedFrame == i ? Color.orange.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityIdentifier("select-frame-\(i)")
                }
                if photos.indices.contains(selectedFrame) {
                    Text(L10n.tr("ipad.03ccf7f28574")).font(.caption.weight(.semibold))
                    MobilePositionFields(position: Binding(get: { positions[selectedFrame] ?? .zero }, set: { positions[selectedFrame] = $0; guided = true }))
                }
                Toggle(L10n.tr("ipad.1451cd3ff100"), isOn: $guided).accessibilityIdentifier("position-guidance")
                Text(guided ? L10n.tr("ipad.1e6c54d4cfc9") : L10n.tr("ipad.eb13eb208f76")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(L10n.tr("ipad.8fc486edfaf6")).font(.headline)
                    if let plan = model.plan { MobilePositionDiagram(plan: plan).frame(height: 280) }
                    Text(L10n.tr("ipad.6bd1217be525")).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup(L10n.tr("ipad.a38fa6d1cdc0")) {
                    if mode == .shift {
                    Toggle(L10n.tr("ipad.c44d573e0600"), isOn: $manualSensor).onChange(of: manualSensor) { _,enabled in
                        if !enabled, let known = sources.first?.sensor { sensorWidth = known.width; sensorHeight = known.height }
                    }
                    if manualSensor {
                        LabeledContent(L10n.tr("ipad.66194cc31a4f")) { TextField(L10n.tr("ipad.3019947b6daf"), value: $sensorWidth, format: .number) }
                        LabeledContent(L10n.tr("ipad.c52c57e0197a")) { TextField(L10n.tr("ipad.bfe2eca40179"), value: $sensorHeight, format: .number) }
                    } else { Text(String(format: L10n.tr("ipad.6f62f1f9443a"), sensorWidth, sensorHeight)).font(.caption) }
                    }
                    Toggle(L10n.tr("ipad.884e937d3d20"), isOn: $options.matchExposure)
                    Toggle(L10n.tr("ipad.a55dd8a88660"), isOn: $options.avoidMotion)
                    Slider(value: $options.seamSoftness, in: 0...20) { Text(L10n.tr("ipad.11b8fec683fe")) }
                }
                Button(L10n.tr("ipad.602ad77cd80f"), action: align).buttonStyle(.borderedProminent)
                    .disabled(model.busy || !validSensor || sources.count < 2).accessibilityIdentifier("align-panorama")
                Divider()
                if mode == .shift {
                Text(L10n.tr("ipad.6f427ab8e70e")).font(.caption.weight(.semibold))
                Picker(L10n.tr("5c30b533510f"), selection: $profileID) {
                    Text(L10n.tr("ipad.416c3478ef2c")).tag(UUID?.none)
                    ForEach(model.profiles) { Text($0.name).tag(Optional($0.id)) }
                }
                Toggle(L10n.tr("ipad.2c1f86e2653a"), isOn: $cropToLCC).toggleStyle(MobileCheckboxStyle())
                    .accessibilityIdentifier("panorama-crop-lcc")
                    .disabled(model.plan?.lccState.map { $0.suggestedCropRect == nil && !cropToLCC } ?? false)
                    .onChange(of: cropToLCC) { _,enabled in
                        if model.plan?.lccState != nil && !dirty { model.setLCCCrop(enabled) }
                    }
                Text(L10n.tr("ipad.70ddfa521391")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.tr("ipad.08b90bbe8907")) {
                    guard let profileID, let plan = model.plan else { return }
                    let offset = guided ? PanoramaPositionReference(sourceIndex: selectedFrame, positionMM: positions[selectedFrame] ?? .zero).profileOffset(in: plan, sensor: sensor) : nil
                    model.correctPanorama(profileID: profileID, offset: offset, body: bodyType, orientation: orientation, cropToCoverage: cropToLCC)
                }.disabled(model.busy || dirty || model.plan == nil || profileID == nil).accessibilityIdentifier("panorama-lcc")
                if let lcc = model.plan?.lccState { Label(lcc.profileName, systemImage: "checkmark.seal"); Text(String(format: L10n.tr("ipad.0858f5e8bf0a"), lcc.coveredFraction * 100)).font(.caption) }
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
            .accessibilityValue(String(format: L10n.tr("ipad.95fedff80e4b"), center.x, center.y))
            .accessibilityIdentifier("shift-frame-\(index)")
    }
}

#endif
