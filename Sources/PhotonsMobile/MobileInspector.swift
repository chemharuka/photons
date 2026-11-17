#if os(iOS)
import SwiftUI
import PhotonsCore
import PhotonsPanorama

struct MobileInspector: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var tab = "Adjust"
    @State private var copiedEdit: EditModel?
    var body: some View {
        VStack(spacing: 0) {
            if let histogram = model.frame?.histogram {
                MobileHistogram(histogram: histogram).frame(height: 110).padding(14)
            }
            if let plan = model.plan {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(plan.sources.count > 1 ? "PANORAMA" : "LCC CORRECTION").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        MobilePositionDiagram(plan: plan, manifest: model.manifest).frame(height: 230)
                        Text("\(Int(plan.outputSize.width)) × \(Int(plan.outputSize.height)) · \(model.manifest?.frames.count ?? plan.sources.count) source(s)").font(.caption)
                        if let lcc = plan.lccState {
                            Label(lcc.profileName, systemImage: "checkmark.seal")
                            Text(String(format: "Coverage %.1f%%", lcc.coveredFraction * 100)).font(.caption)
                        }
                        if let note = model.lccPositionNote { Text(note).font(.caption).foregroundStyle(.orange) }
                        if model.manifest != nil && plan.sources.count == 1 {
                            Text("Post-export LCC uses recorded geometry and rendered RGB. For the closest match, apply LCC to the original sources before stitching.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if let manifest = model.manifest {
                            ForEach(Array(manifest.frames.enumerated()), id: \.offset) { index,frame in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(frame.filename).font(.caption.weight(.semibold))
                                    if let position = manifest.position(of: index, offset: manifest.profileOffsetMM) {
                                        Text(String(format: "X %+.1f · Y %+.1f mm", position.x, position.y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } else {
                        ForEach(Array(plan.sources.enumerated()), id: \.offset) { index,source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.url.lastPathComponent).font(.caption.weight(.semibold))
                                if plan.registrationMode == .perspective {
                                    let rect = plan.sourceRect(index)
                                    Text(String(format: "Canvas X %.0f · Y %.0f px", rect.midX, rect.midY)).font(.caption).foregroundStyle(.secondary)
                                } else if let sensor = source.sensor {
                                    let rect = plan.sensorRect(index), offset = plan.lccState?.offsetMM ?? .zero
                                    let x = (rect.midX - plan.size.width / 2) * sensor.width / source.size.width - offset.x
                                    let y = (plan.size.height / 2 - rect.midY) * sensor.height / source.size.height - offset.y
                                    Text(String(format: "X %+.1f · Y %+.1f mm", x,y)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                        }
                        }
                    }.padding(16)
                }
            } else if model.active != nil {
                Picker("Inspector", selection: $tab) {
                    ForEach(["Adjust", "Color", "Transform", "History"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).padding(.horizontal, 10)
                Form {
                    switch tab {
                    case "Adjust": adjustments
                    case "Color": colors
                    case "Transform": transforms
                    default: history
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                HStack {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.history.canUndo).accessibilityIdentifier("undo-edit")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.history.canRedo)
                    Spacer()
                    Menu {
                        Button("Copy settings") { copiedEdit = model.edit }
                        Button("Paste settings") { if let copiedEdit { model.mutate("Paste settings") { $0 = copiedEdit } } }.disabled(copiedEdit == nil)
                        Button("Restore imported settings", role: .destructive) { model.reset() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }.padding(16)
            } else {
                ContentUnavailableView("Inspector", systemImage: "slider.horizontal.3", description: Text("Select a photo to view its histogram and adjustments."))
            }
        }.background(Color(white: 0.105)).disabled(model.busy || model.selectionLoading)
    }
    private func rows(_ title: String, _ controls: [DevelopControl]) -> some View {
        Section(title) {
            ForEach(controls) { row in
                MobileSlider(title: row.title, value: Binding(get: { model.edit[keyPath: row.keyPath] }, set: { model.update(row.keyPath, $0) }),
                             range: row.range, step: row.quantum > 0 ? row.quantum : (row.range.upperBound <= 3 ? 0.01 : 0.1),
                             commit: { model.commit(row.title) })
                    .contextMenu { Button("Reset") { model.mutate("Reset \(row.title)") { $0[keyPath: row.keyPath] = row.defaultValue } } }
                    .accessibilityIdentifier("adjust-\(row.id)")
            }
        }
    }
    private var adjustments: some View {
        Group {
            Section("White balance") {
                MobileSlider(title: "Temperature", value: Binding(get: { model.edit.light.temperature ?? 6500 }, set: { model.edit.light.temperature = min(TemperatureScale.kelvinRange.upperBound, max(TemperatureScale.kelvinRange.lowerBound, $0.isFinite ? $0 : 6500)); model.render() }), range: TemperatureScale.kelvinRange, step: 50) { model.commit("White balance") }
                MobileSlider(title: "Tint", value: Binding(get: { model.edit.light.tint ?? 0 }, set: { model.edit.light.tint = $0; model.render() }), range: -150...150) { model.commit("Tint") }
                Button("As shot") { model.mutate("As shot") { $0.light.temperature = nil; $0.light.tint = nil } }
            }
            rows("Light", DevelopControls.lightRows)
            rows("Color", DevelopControls.colorRows)
            rows("Texture & clarity", DevelopControls.textureClarityRows)
            rows("Noise reduction", DevelopControls.nonBayerRows)
            rows("Sharpening", DevelopControls.sharpenRows)
            rows("Vignette", DevelopControls.vignetteRows)
            rows("Dehaze", DevelopControls.dehazeRows)
            rows("Grain", DevelopControls.grainRows)
            Section("Rating") {
                HStack {
                    ForEach(1...5, id: \.self) { rating in
                        Button { model.setRating(rating) } label: {
                            Image(systemName: rating <= (model.photos.first { $0.id == model.active?.id }?.rating ?? 0) ? "star.fill" : "star")
                        }.buttonStyle(.borderless)
                    }
                    Button("Clear") { model.setRating(0) }.font(.caption)
                }
            }
        }
    }
    private var colors: some View {
        Group {
            Section {
                Toggle("Black & white", isOn: Binding(get: { model.edit.color.blackAndWhite }, set: { value in model.mutate("Black & white") { $0.color.blackAndWhite = value } }))
            }
            ForEach(Array(["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"].enumerated()), id: \.offset) { i,name in
                Section(name) {
                    colorSlider("Hue", index: i, path: \.hue)
                    colorSlider("Saturation", index: i, path: \.saturation)
                    colorSlider("Luminance", index: i, path: \.luminance)
                    if model.edit.color.blackAndWhite { colorSlider("B&W mix", index: i, path: \.mix) }
                }
            }
            grading("Shadows", path: \.colorGrading.shadows)
            grading("Midtones", path: \.colorGrading.midtones)
            grading("Highlights", path: \.colorGrading.highlights)
            Section("Calibration") {
                direct("Shadow tint", \.calibration.shadowTint, -100...100)
                direct("Red hue", \.calibration.redHue, -100...100)
                direct("Red saturation", \.calibration.redSat, -100...100)
                direct("Green hue", \.calibration.greenHue, -100...100)
                direct("Green saturation", \.calibration.greenSat, -100...100)
                direct("Blue hue", \.calibration.blueHue, -100...100)
                direct("Blue saturation", \.calibration.blueSat, -100...100)
            }
        }
    }
    private func colorSlider(_ title: String, index: Int, path: WritableKeyPath<HSLBand, Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit.color.bands[index][keyPath: path] }, set: { model.edit.color.bands[index][keyPath: path] = $0; model.render() }), range: -100...100) { model.commit("HSL \(title)") }
    }
    private func grading(_ title: String, path: WritableKeyPath<EditModel, GradeWheel>) -> some View {
        Section("Color grading · \(title)") {
            direct("Hue", path.appending(path: \.hue), 0...360)
            direct("Saturation", path.appending(path: \.saturation), 0...100)
            direct("Lightness", path.appending(path: \.lightness), -100...100)
        }
    }
    private func direct(_ title: String, _ path: WritableKeyPath<EditModel, Double>, _ range: ClosedRange<Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit[keyPath: path] }, set: { model.update(path, $0) }), range: range) { model.commit(title) }
    }
    private var transforms: some View {
        Group {
            Section("Orientation") {
                Button("Rotate clockwise", systemImage: "rotate.right") { model.mutate("Rotate") { _ = $0.turn(clockwise: true) } }
                Toggle("Flip horizontal", isOn: Binding(get: { model.edit.geometry.flipHorizontal }, set: { value in model.mutate("Flip") { $0.geometry.flipHorizontal = value } }))
                Toggle("Flip vertical", isOn: Binding(get: { model.edit.geometry.flipVertical }, set: { value in model.mutate("Flip") { $0.geometry.flipVertical = value } }))
                direct("Straighten", \.geometry.rotationDegrees, -45...45)
            }
            Section("Crop · normalized coordinates") {
                crop("Left", \.x); crop("Top", \.y); crop("Width", \.width); crop("Height", \.height)
                Button("Reset crop") { model.mutate("Reset crop") { $0.geometry.crop = .full } }
            }
        }
    }
    private func crop(_ title: String, _ path: WritableKeyPath<NormalizedRect, Double>) -> some View {
        MobileSlider(title: title, value: Binding(get: { model.edit.geometry.crop[keyPath: path] }, set: {
            model.edit.geometry.crop[keyPath: path] = $0
            model.edit.geometry.crop = model.edit.geometry.crop.clamped(); model.render()
        }), range: title == "Width" || title == "Height" ? 0.01...1 : 0...0.99, step: 0.01) { model.commit("Crop") }
    }
    private var history: some View {
        Section("History") {
            ForEach(model.history.snapshots.reversed(), id: \.seq) { entry in
                Button { model.jump(entry.seq) } label: {
                    HStack { Text(entry.label.isEmpty ? "Adjustment" : entry.label); Spacer(); if entry.seq == model.history.currentSeq { Image(systemName: "checkmark") } }
                }
            }
            Button("Restore imported settings", role: .destructive) { model.reset() }
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
struct MobileHistogram: View {
    let histogram: Histogram
    var body: some View {
        Canvas { context,size in
            let colors: [Color] = [.red, .green, .blue]
            for (index,channel) in [histogram.red, histogram.green, histogram.blue].enumerated() {
                let values = channel.bins + (histogram.headroom > 1 ? channel.hdrBins : [])
                let peak = max(1,values.max() ?? 1)
                var path = Path(); path.move(to: CGPoint(x: 0,y: size.height))
                for (i,value) in values.enumerated() {
                    path.addLine(to: CGPoint(x: Double(i) / Double(max(1,values.count - 1)) * size.width,
                                            y: size.height * (1 - log1p(Double(value)) / log1p(Double(peak)))))
                }
                path.addLine(to: CGPoint(x: size.width,y: size.height)); path.closeSubpath()
                context.fill(path, with: .color(colors[index].opacity(0.35)))
            }
        }.background(Color.black.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityLabel("RGB histogram")
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
        }.accessibilityLabel("Relative source positions")
    }
}
#endif
