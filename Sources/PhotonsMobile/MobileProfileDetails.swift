#if os(iOS)
import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

struct MobileProfileDetails: View {
    let engine: MobileEngine
    let id: UUID
    @State private var profile: LCCLensProfile?
    @State private var error: String?
    var body: some View {
        Form {
            if let profile {
                Section(L10n.tr("ipad.8cd6944d65f3")) {
                    LabeledContent(L10n.tr("d44e9b3d3b31"),value: profile.name)
                    LabeledContent(L10n.tr("dacf07026026"),value: profile.camera)
                    if let aperture = profile.aperture { LabeledContent(L10n.tr("e3df0be2e19a"),value: String(format: "f/%g",aperture)) }
                    LabeledContent(L10n.tr("ipad.6a1540145498"),value: LCCProfileSummary(profile).calibrationBody?.name ?? L10n.tr("ipad.b37c7879f6c3"))
                    LabeledContent(L10n.tr("ipad.d70b9e24bca2")) { Text(profile.createdAt,style: .date) }
                    LabeledContent(L10n.tr("ipad.fbdd0904cfa1"),value: "\(profile.schemaVersion)")
                    LabeledContent(L10n.tr("ipad.2c7635a09933"),value: "\(profile.captures.count)")
                    Text(L10n.tr("lcc.profile.compatibility")).font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: LCCProfileStore().url(for: id)) { Label(L10n.tr("ipad.0590386ef566"),systemImage: "square.and.arrow.up") }
                }
                if !profile.notes.isEmpty { Section(L10n.tr("ipad.8a7525b1492f")) { Text(profile.notes).textSelection(.enabled) } }
                ForEach(profile.orientations) { orientation in
                    let captures = profile.captures(for: orientation)
                    Section {
                        MobileProfileCoverage(captures: captures).frame(height: 190)
                            .accessibilityIdentifier("profile-coverage-\(orientation.rawValue)")
                        Text(String(format: L10n.tr("ipad.a391b22a7b4c"),
                            captures.map(\.shiftX).min() ?? 0,captures.map(\.shiftX).max() ?? 0,
                            captures.map(\.shiftY).min() ?? 0,captures.map(\.shiftY).max() ?? 0)).font(.caption.monospacedDigit())
                        Text(L10n.tr("ipad.059ff47cbfc0")).font(.caption).foregroundStyle(.secondary)
                        ForEach(captures) { capture in
                            DisclosureGroup {
                                captureDetails(capture)
                            } label: { Text(capture.filename).lineLimit(2) }
                            .accessibilityIdentifier("profile-capture-\(capture.id.uuidString)")
                        }
                    } header: { Text(L10n.tr("ipad.5725b0ce1bfc", String(describing: (orientation.title)), String(describing: (captures.count)))) }
                }
                Section {
                    Text(L10n.tr("462dcac8baeb"))
                    Text(L10n.tr("89e848ef8755"))
                }.font(.caption).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(.red)
                Button(L10n.tr("ipad.942087cc2d41")) { Task { await load() } }
            } else { ProgressView(L10n.tr("ipad.f5d7beb0a27c")) }
        }
        .navigationTitle(profile?.name ?? L10n.tr("ipad.5e1b2d89ee2a"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: id) { await load() }
    }
    private func load() async {
        do { profile = try await engine.profile(id); error = nil }
        catch { self.error = error.localizedDescription }
    }
    @ViewBuilder private func captureDetails(_ capture: LCCProfileCapture) -> some View {
        LabeledContent(L10n.tr("ipad.111dab75a809"),value: String(format: L10n.tr("ipad.9126f1282784"),capture.shiftX,capture.shiftY))
        LabeledContent(L10n.tr("ipad.29ee9c7ef27d"),value: String(format: L10n.tr("ipad.6f62f1f9443a"),capture.sensorWidth,capture.sensorHeight))
        LabeledContent(L10n.tr("ipad.2cb7d0483082"),value: "\(capture.pixelWidth) × \(capture.pixelHeight)")
        if let iso = capture.iso { LabeledContent("ISO",value: String(format: "%g",iso)) }
        if let seconds = capture.exposureSeconds { LabeledContent(L10n.tr("ipad.239bb77f5ec3"),value: String(format: L10n.tr("ipad.b42125d9d18b"),seconds)) }
        if let date = capture.capturedAt { LabeledContent(L10n.tr("ipad.8a03fa9ad749"),value: date) }
        if let body = capture.bodyOrientation { LabeledContent(L10n.tr("ipad.88930b71fe3b"),value: "\(body.rawValue)°") }
        gridDetails(capture.grid,title: L10n.tr("ipad.0949587a78e9"))
        if let grid = capture.renderGrid { gridDetails(grid,title: L10n.tr("ipad.f9b87f1487ec")) }
    }
    @ViewBuilder private func gridDetails(_ grid: LCCMeasurementGrid,title: String) -> some View {
        LabeledContent(title,value: "\(grid.width) × \(grid.height) · \(grid.channels.joined(separator: "/"))")
        Text(grid.space).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }
}

struct MobileProfileCoverage: View {
    let captures: [LCCProfileCapture]
    static func bounds(_ captures: [LCCProfileCapture]) -> CGRect { captures.reduce(.null) { $0.union($1.fieldRect) } }
    var body: some View {
        Canvas { context,size in
            let bounds = Self.bounds(captures)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return }
            let scale = min((size.width-24)/bounds.width,(size.height-24)/bounds.height)
            let origin = CGPoint(x: (size.width-bounds.width*scale)/2,y: (size.height-bounds.height*scale)/2)
            for capture in captures {
                let field = capture.fieldRect
                let rect = CGRect(x: origin.x+(field.minX-bounds.minX)*scale,y: origin.y+(bounds.maxY-field.maxY)*scale,
                                  width: field.width*scale,height: field.height*scale)
                context.fill(Path(rect),with: .color(.cyan.opacity(0.045)))
                context.stroke(Path(rect),with: .color(.cyan.opacity(0.4)),lineWidth: 0.8)
                context.fill(Path(ellipseIn: CGRect(x: rect.midX-2,y: rect.midY-2,width: 4,height: 4)),with: .color(.primary.opacity(0.7)))
            }
        }.background(.quaternary,in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel(L10n.tr("ipad.084018dd2281"))
    }
}
#endif
