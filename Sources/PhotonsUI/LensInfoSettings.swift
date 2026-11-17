import SwiftUI
import PhotonsLocalization
import PhotonsPanorama

/// Reserved entry point for future distortion profiles; no solver or calibration data yet.
enum LensCorrectionFeature {
    case lcc, distortion
    var isAvailable: Bool { self == .lcc }
    var title: String { L10n.tr(self == .lcc ? "lensInfo.configureLCC" : "lensInfo.configureDistortion") }
}

struct LensInfoSettingsView: View {
    @ObservedObject var model: LCCProfileLibraryModel = .shared
    var configure: (UUID?) -> Void = { LCCProfileLibraryWindowController.shared.open(select: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.tr("lensInfo.sharedList")).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                List(selection: $model.selected) {
                    ForEach(model.profiles) { profile in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name).lineLimit(2)
                            Text(profile.camera).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }.padding(.vertical, 4).tag(profile.id)
                    }
                }.frame(minWidth: 220, minHeight: 160, maxHeight: 160)
                    .accessibilityIdentifier("settings.lenses.list")
                VStack(alignment: .leading, spacing: 10) {
                    Button(LensCorrectionFeature.lcc.title) { configure(model.selected) }
                        .disabled(model.busy).accessibilityIdentifier("settings.lenses.configureLCC")
                    Button {} label: {
                        VStack(spacing: 3) {
                            Text(LensCorrectionFeature.distortion.title)
                            Text(L10n.tr("lensInfo.inDevelopment")).font(.caption)
                        }
                    }.disabled(!LensCorrectionFeature.distortion.isAvailable)
                        .help(L10n.tr("lensInfo.distortionHint"))
                        .accessibilityIdentifier("settings.lenses.configureDistortion")
                }.frame(width: 148, alignment: .leading)
            }
            if let summary = model.profiles.first(where: { $0.id == model.selected }) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(summary.name).font(.headline)
                    LabeledContent(L10n.tr("lensInfo.camera"), value: summary.camera)
                    if let aperture = summary.aperture { LabeledContent(L10n.tr("lensInfo.aperture"), value: "f/\(aperture.formatted())") }
                    LabeledContent("LCC", value: L10n.tr("lensInfo.captureCount", String(summary.captureCount)))
                    LabeledContent(L10n.tr("lensInfo.distortion"), value: L10n.tr("lensInfo.inDevelopment"))
                }.font(.callout).padding(14)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else if model.busy {
                ProgressView().controlSize(.small)
            } else {
                Text(L10n.tr("lensInfo.empty")).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.onAppear { model.ensureLoaded() }
    }
}
