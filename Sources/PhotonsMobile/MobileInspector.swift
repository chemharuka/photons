#if os(iOS)
import PhotonsLocalization
import SwiftUI
import PhotonsCore
import PhotonsPanorama

struct MobileInspector: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var tab = L10n.tr("ipad.fd8a7d7b3e7b")
    @State private var copiedEdit: EditModel?
    var body: some View {
        VStack(spacing: 0) {
            if let histogram = model.frame?.histogram {
                MobileHistogram(histogram: histogram,hdr: model.hdr).padding(14)
            }
            if let plan = model.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(plan.sources.count > 1 ? L10n.tr("ipad.bcd646097a48") : L10n.tr("ipad.6f427ab8e70e")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        MobilePositionDiagram(plan: plan, manifest: model.manifest).frame(height: 230)
                        Text(L10n.tr("ipad.30e7414d5987", String(describing: (Int(plan.outputSize.width))), String(describing: (Int(plan.outputSize.height))), String(describing: (model.manifest?.frames.count ?? plan.sources.count)))).font(.caption)
                        if let lcc = plan.lccState {
                            Label(lcc.profileName, systemImage: "checkmark.seal")
                            Text(String(format: L10n.tr("ipad.0858f5e8bf0a"), lcc.coveredFraction * 100)).font(.caption)
                        }
                        if let note = model.lccPositionNote { Text(note).font(.caption).foregroundStyle(.orange) }
                        if model.manifest != nil && plan.sources.count == 1 {
                            Text(L10n.tr("ipad.2458256a9eb2"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let manifest = model.manifest {
                            ForEach(Array(manifest.frames.enumerated()), id: \.offset) { index,frame in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(frame.filename).font(.caption.weight(.semibold))
                                    if let position = manifest.position(of: index, offset: manifest.profileOffsetMM) {
                                        Text(String(format: L10n.tr("ipad.9126f1282784"), position.x, position.y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                        ForEach(Array(plan.sources.enumerated()), id: \.offset) { index,source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.url.lastPathComponent).font(.caption.weight(.semibold))
                                if plan.registrationMode == .perspective {
                                    let rect = plan.sourceRect(index)
                                    Text(String(format: L10n.tr("ipad.7134affd85e6"), rect.midX, rect.midY)).font(.caption).foregroundStyle(.secondary)
                                } else if let sensor = source.sensor {
                                    let rect = plan.sensorRect(index), offset = plan.lccState?.offsetMM ?? .zero
                                    let x = (rect.midX - plan.size.width / 2) * sensor.width / source.size.width - offset.x
                                    let y = (plan.size.height / 2 - rect.midY) * sensor.height / source.size.height - offset.y
                                    Text(String(format: L10n.tr("ipad.9126f1282784"), x,y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        }
                    }.padding(16)
                }
            } else if model.active != nil {
                Picker(L10n.tr("ipad.da188e3b1cef"), selection: $tab) {
                    ForEach([L10n.tr("ipad.fd8a7d7b3e7b"), L10n.tr("e40fffdb9798"), L10n.tr("ca4842bc9e80"), L10n.tr("5467922dce50")], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 10)
                Form {
                    switch tab {
                    case L10n.tr("ipad.fd8a7d7b3e7b"): adjustments
                    case L10n.tr("e40fffdb9798"): colors
                    case L10n.tr("ca4842bc9e80"): transforms
                    default: history
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                HStack {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.history.canUndo).accessibilityIdentifier("undo-edit")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.history.canRedo)
                    Spacer()
                    Menu {
                        Button(L10n.tr("ipad.25e71bb4b25e")) { copiedEdit = model.edit }
                        Button(L10n.tr("d24cf4a6b02b")) { if let copiedEdit { model.mutate(L10n.tr("d24cf4a6b02b")) { $0 = copiedEdit } } }.disabled(copiedEdit == nil)
                        Button(L10n.tr("ipad.53fc2db3b345"), role: .destructive) { model.reset() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.padding(16)
            } else {
                ContentUnavailableView(L10n.tr("ipad.da188e3b1cef"), systemImage: "slider.horizontal.3", description: Text(L10n.tr("ipad.0ee5f146bb5e")))
            }
        }.background(Color(white: 0.105)).disabled(model.busy || model.selectionLoading)
    }
    private func rows(_ title: String, _ controls: [DevelopControl]) -> some View {
        Section(title) {
            ForEach(controls) { row in
                MobileSlider(title: row.title, value: Binding(get: { model.edit[keyPath: row.keyPath] }, set: { model.update(row.keyPath, $0) }),
                             range: row.range, step: row.quantum > 0 ? row.quantum : (row.range.upperBound <= 3 ? 0.01 : 0.1),
                             commit: { model.commit(row.title) })
                    .contextMenu { Button(L10n.tr("panorama.tone.reset")) { model.mutate(L10n.tr("87a894ed1aec", String(describing: (row.title)))) { $0[keyPath: row.keyPath] = row.defaultValue } } }
                    .accessibilityIdentifier("adjust-\(row.id)")
            }
        }
    }
    private var adjustments: some View {
        Group {
            Section(L10n.tr("ipad.5631553e4ddc")) {
                MobileSlider(title: L10n.tr("84ac609620e5"), value: Binding(get: { model.edit.light.temperature ?? 6500 }, set: { model.edit.light.temperature = min(TemperatureScale.kelvinRange.upperBound, max(TemperatureScale.kelvinRange.lowerBound, $0.isFinite ? $0 : 6500)); model.render() }), range: TemperatureScale.kelvinRange, step: 50) { model.commit(L10n.tr("ipad.5631553e4ddc")) }
                MobileSlider(title: L10n.tr("5bddf6a1c0f5"), value: Binding(get: { model.edit.light.tint ?? 0 }, set: { model.edit.light.tint = $0; model.render() }), range: -150...150) { model.commit(L10n.tr("5bddf6a1c0f5")) }
                Button(L10n.tr("ipad.fcc834176527")) { model.mutate(L10n.tr("ipad.fcc834176527")) { $0.light.temperature = nil; $0.light.tint = nil } }
            }
            rows(L10n.tr("ipad.lightAdjustments"), DevelopControls.lightRows)
            rows(L10n.tr("e40fffdb9798"), DevelopControls.colorRows)
            rows(L10n.tr("ipad.d489ea05c935"), DevelopControls.textureClarityRows)
            rows(L10n.tr("ipad.906770cf4616"), DevelopControls.nonBayerRows)
            rows(L10n.tr("fc538f246da7"), DevelopControls.sharpenRows)
            rows(L10n.tr("da89443e202b"), DevelopControls.vignetteRows)
            rows(L10n.tr("0665cca26772"), DevelopControls.dehazeRows)
            rows(L10n.tr("b82bd426d236"), DevelopControls.grainRows)
            Section(L10n.tr("9c55a439d71f")) {
                HStack {
                    ForEach(1...5, id: \.self) { rating in
                        Button { model.setRating(rating) } label: {
                            Image(systemName: rating <= (model.photos.first { $0.id == model.active?.id }?.rating ?? 0) ? "star.fill" : "star")
                        }.buttonStyle(.borderless)
                    }
                    Button(L10n.tr("ipad.83b12c2216ef")) { model.setRating(0) }.font(.caption)
                }
            }
        }
    }
    private var colors: some View {
        Group {
            Section {
                Toggle(L10n.tr("ipad.8e262729e143"), isOn: Binding(get: { model.edit.color.blackAndWhite }, set: { value in model.mutate(L10n.tr("ipad.8e262729e143")) { $0.color.blackAndWhite = value } }))
            }
            ForEach(Array([L10n.tr("0eb7ee7e38ef"), L10n.tr("1ad702b18a4d"), L10n.tr("c732e4d7e380"), L10n.tr("84b34ffba5aa"), L10n.tr("ipad.7a4721a879cb"), L10n.tr("52f354ecfccb"), L10n.tr("3d0158cb7cfd"), L10n.tr("e2d7f32e6c98")].enumerated()), id: \.offset) { i,name in
                Section(name) {
                    colorSlider(L10n.tr("3ff6d1c07cfc"), index: i, path: \.hue)
                    colorSlider(L10n.tr("762f17e26780"), index: i, path: \.saturation)
                    colorSlider(L10n.tr("8e2f643ad160"), index: i, path: \.luminance)
                    if model.edit.color.blackAndWhite { colorSlider(L10n.tr("ipad.0b62c81595f1"), index: i, path: \.mix) }
                }
            }
            grading(L10n.tr("a0fb1c62d0e8"), path: \.colorGrading.shadows)
            grading(L10n.tr("280d2d14de93"), path: \.colorGrading.midtones)
            grading(L10n.tr("f799c2308083"), path: \.colorGrading.highlights)
            Section(L10n.tr("45230cc916f6")) {
                direct(L10n.tr("aed6b38a0164"), \.calibration.shadowTint, -100...100)
                direct(L10n.tr("2304051c2cb0"), \.calibration.redHue, -100...100)
                direct(L10n.tr("21fae3c845b8"), \.calibration.redSat, -100...100)
                direct(L10n.tr("d9cea627e2e9"), \.calibration.greenHue, -100...100)
                direct(L10n.tr("4940bdebf9cb"), \.calibration.greenSat, -100...100)
                direct(L10n.tr("290ad7aed661"), \.calibration.blueHue, -100...100)
                direct(L10n.tr("2bcc4344dfe7"), \.calibration.blueSat, -100...100)
            }
        }
    }
    private func colorSlider(_ title: String, index: Int, path: WritableKeyPath<HSLBand, Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit.color.bands[index][keyPath: path] }, set: { model.edit.color.bands[index][keyPath: path] = $0; model.render() }), range: -100...100) { model.commit("HSL \(title)") }
    }
    private func grading(_ title: String, path: WritableKeyPath<EditModel, GradeWheel>) -> some View {
        Section(L10n.tr("ipad.fdeaad6643b3", String(describing: (title)))) {
            direct(L10n.tr("3ff6d1c07cfc"), path.appending(path: \.hue), 0...360)
            direct(L10n.tr("762f17e26780"), path.appending(path: \.saturation), 0...100)
            direct(L10n.tr("c5fce2a15bee"), path.appending(path: \.lightness), -100...100)
        }
    }
    private func direct(_ title: String, _ path: WritableKeyPath<EditModel, Double>, _ range: ClosedRange<Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit[keyPath: path] }, set: { model.update(path, $0) }), range: range) { model.commit(title) }
    }
    private var transforms: some View {
        Group {
            Section(L10n.tr("slices.orientation")) {
                Button(L10n.tr("ipad.fb594c58c73d"), systemImage: "rotate.right") { model.mutate(L10n.tr("0cf81e4c2481")) { _ = $0.turn(clockwise: true) } }
                Toggle(L10n.tr("ipad.9692a0ce7511"), isOn: Binding(get: { model.edit.geometry.flipHorizontal }, set: { value in model.mutate(L10n.tr("3733e06a5224")) { $0.geometry.flipHorizontal = value } }))
                Toggle(L10n.tr("ipad.30122ff97c9a"), isOn: Binding(get: { model.edit.geometry.flipVertical }, set: { value in model.mutate(L10n.tr("3733e06a5224")) { $0.geometry.flipVertical = value } }))
                direct(L10n.tr("7df1c3a41535"), \.geometry.rotationDegrees, -45...45)
            }
            Section(L10n.tr("ipad.460a1ef164d0")) {
                crop(L10n.tr("ipad.58eb9032e3bb"), \.x); crop(L10n.tr("ipad.d5cdfcf7ff75"), \.y); crop(L10n.tr("ipad.3019947b6daf"), \.width); crop(L10n.tr("ipad.bfe2eca40179"), \.height)
                Button(L10n.tr("ipad.994feef62ef2")) { model.mutate(L10n.tr("ipad.994feef62ef2")) { $0.geometry.crop = .full } }
            }
        }
    }
    private func crop(_ title: String, _ path: WritableKeyPath<NormalizedRect, Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit.geometry.crop[keyPath: path] }, set: {
            model.edit.geometry.crop[keyPath: path] = $0
            model.edit.geometry.crop = model.edit.geometry.crop.clamped(); model.render()
        }), range: title == L10n.tr("ipad.3019947b6daf") || title == L10n.tr("ipad.bfe2eca40179") ? 0.01...1 : 0...0.99, step: 0.01) { model.commit(L10n.tr("e9f8face2f69")) }
    }
    private var history: some View {
        Section(L10n.tr("5467922dce50")) {
            ForEach(model.history.snapshots.reversed(), id: \.seq) { entry in
                Button { model.jump(entry.seq) } label: {
                    HStack { Text(entry.label.isEmpty ? L10n.tr("ipad.c416069b7f61") : entry.label); Spacer(); if entry.seq == model.history.currentSeq { Image(systemName: "checkmark") } }
                }
            }
            Button(L10n.tr("ipad.53fc2db3b345"), role: .destructive) { model.reset() }
        }
    }
}
struct MobileSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var commit: () -> Void
    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...2)))
                    .font(.caption.monospacedDigit()).multilineTextAlignment(.trailing).frame(width: 72)
                    .keyboardType(.numbersAndPunctuation).onSubmit { value = min(range.upperBound, max(range.lowerBound, value.isFinite ? value : 0)); commit() }
            }
            Slider(value: $value, in: range, step: step, onEditingChanged: { editing in if !editing { commit() } }).accessibilityLabel(title)
        }.padding(.vertical, 3)
    }
}
struct MobilePositionDiagram: View {
    let plan: PanoramaPlan
    var manifest: PanoramaManifest? = nil
    private var canvasSize: CGSize { manifest?.canvas ?? plan.size }
    private var frames: [(String, CGRect)] {
        if let manifest {
            return manifest.frames.map { ($0.filename, $0.rect.applying(CGAffineTransform(scaleX: manifest.canvas.width, y: manifest.canvas.height))) }
        }
        return plan.sources.enumerated().map { ($0.element.url.deletingPathExtension().lastPathComponent, plan.sourceRect($0.offset)) }
    }
    var body: some View {
        GeometryReader { geometry in
            let scale = min((geometry.size.width - 24) / max(1,canvasSize.width), (geometry.size.height - 24) / max(1,canvasSize.height))
            let x = (geometry.size.width - canvasSize.width * scale) / 2
            let y = (geometry.size.height - canvasSize.height * scale) / 2
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.2)
                ForEach(Array(frames.enumerated()), id: \.offset) { index,source in
                    let rect = source.1
                    let color = [Color.cyan, .purple, .orange, .green][index % 4]
                    Rectangle().fill(color.opacity(0.13)).overlay(Rectangle().stroke(color, lineWidth: 1.5))
                        .overlay(Text(source.0).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.5))
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .offset(x: x + rect.minX * scale, y: y + rect.minY * scale)
                }
            }.clipShape(RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel(L10n.tr("ipad.7eb33a4d6540"))
    }
}
#endif
