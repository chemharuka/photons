#if os(iOS)
import SwiftUI
import PhotonsPanorama
import PhotonsLocalization

/// Touch-sized versions of the Mac body-placement diagrams, using the same travel geometry.
struct MobileBodyOrientationPicker: View {
    let cameraBody: PanoramaCameraBody
    @Binding var selection: PanoramaBodyOrientation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                ForEach(PanoramaBodyOrientation.allCases) { angle in
                    Button { selection = angle } label: {
                        VStack(spacing: 4) {
                            diagram(angle).frame(height: 42)
                            Text("\(angle.rawValue)°").font(.caption.weight(.semibold))
                            Text(cameraBody.placementLabel(angle)).font(.system(size: 10))
                                .lineLimit(2).minimumScaleFactor(0.8).frame(height: 26)
                        }.multilineTextAlignment(.center).padding(.vertical, 8).padding(.horizontal, 3)
                            .frame(maxWidth: .infinity)
                            .background(selection == angle ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selection == angle ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selection == angle ? 1.5 : 0.6))
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(angle.rawValue)° \(cameraBody.placementLabel(angle))")
                        .accessibilityValue(selection == angle ? "Selected" : "Not selected")
                        .accessibilityIdentifier("panorama.body.orientation.\(angle.rawValue)")
                }
            }
            Text(L10n.tr("444399a3f9ce")).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func diagram(_ angle: PanoramaBodyOrientation) -> some View {
        Canvas { context, size in
            let range = cameraBody.travel(at: angle).coverage(sensor: .init(width: 12, height: 12, source: "Diagram"), centered: false)
            let scale = min(min(52, max(1, size.width - 6)) / range.width, 34 / range.height)
            let rect = CGRect(x: (size.width - range.width * scale) / 2, y: (size.height - range.height * scale) / 2,
                              width: range.width * scale, height: range.height * scale)
            let zero = CGPoint(x: rect.minX - range.minX * scale, y: rect.minY - range.minY * scale)
            let color: Color = selection == angle ? .accentColor : .primary
            context.fill(Path(rect), with: .color(color.opacity(0.08)))
            context.stroke(Path(rect), with: .color(color.opacity(0.8)), lineWidth: 1.3)
            var cross = Path()
            cross.move(to: CGPoint(x: zero.x - 4, y: zero.y)); cross.addLine(to: CGPoint(x: zero.x + 4, y: zero.y))
            cross.move(to: CGPoint(x: zero.x, y: zero.y - 4)); cross.addLine(to: CGPoint(x: zero.x, y: zero.y + 4))
            context.stroke(cross, with: .color(color), lineWidth: 1.3)
        }.accessibilityHidden(true)
    }
}

struct MobileCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.title3).foregroundStyle(configuration.isOn ? Color.accentColor : .secondary)
                configuration.label.foregroundStyle(.primary)
                Spacer(minLength: 0)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
#endif
