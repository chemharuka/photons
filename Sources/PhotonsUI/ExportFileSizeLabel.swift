import SwiftUI
import PhotonsExport
import PhotonsLocalization

enum ExportFileSizeText {
    static func summary(_ estimate: ExportFileSizeEstimate?) -> String {
        guard let estimate else { return L10n.tr("export.estimatedSize.unknown") }
        let unit: (Double, String)
        if estimate.upperBytes >= 1_000_000_000 { unit = (1_000_000_000, "GB") }
        else if estimate.upperBytes >= 1_000_000 { unit = (1_000_000, "MB") }
        else { unit = (1_000, "KB") }
        func number(_ bytes: Int64) -> String {
            let value = Double(bytes) / unit.0
            return String(format: value < 10 ? "%.1f" : "%.0f", locale: Locale.current, value)
        }
        let lower = number(estimate.lowerBytes), upper = number(estimate.upperBytes)
        let range = lower == upper ? "\(upper) \(unit.1)" : "\(lower)–\(upper) \(unit.1)"
        return L10n.tr(estimate.fileCount > 1 ? "export.estimatedSize.total" : "export.estimatedSize.single", range)
    }
}

struct ExportFileSizeLabel: View {
    let estimate: ExportFileSizeEstimate?
    var identifier = "export.estimatedSize"
    var body: some View {
        Text(ExportFileSizeText.summary(estimate))
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.middle)
            .help(ExportFileSizeText.summary(estimate) + "\n" + L10n.tr("export.estimatedSize.hint"))
            .accessibilityIdentifier(identifier)
    }
}
