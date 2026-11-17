#if os(iOS)
import PhotonsLocalization
import SwiftUI

struct MobileCacheSettings: View {
    @ObservedObject var model: MobileWorkspaceModel
    @State private var usage: MobileEngine.CacheUsage?
    @State private var clearing = false
    @State private var confirm = false
    @State private var error: String?
    private func size(_ value: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(value),countStyle: .file) }
    var body: some View {
        Section {
            if let usage {
                LabeledContent(L10n.tr("ipad.00ca4dac69af"),value: size(usage.diskBytes)).accessibilityIdentifier("cache-disk-size")
                LabeledContent(L10n.tr("ipad.e13d6ff8afe0"),value: "\(usage.files)")
                    .accessibilityElement(children: .ignore).accessibilityLabel(L10n.tr("ipad.e13d6ff8afe0"))
                    .accessibilityValue("\(usage.files)").accessibilityIdentifier("cache-file-count")
                LabeledContent(L10n.tr("ipad.a3c1a9b7f515"),value: size(usage.memoryBytes))
            } else { ProgressView(L10n.tr("ipad.5c13f16b760f")) }
            Button(L10n.tr("ipad.44bdad1e5541")) { Task { await refresh() } }.disabled(clearing)
            Button(L10n.tr("ipad.5e993417dbce"),role: .destructive) { confirm = true }
                .disabled(model.busy || clearing).accessibilityIdentifier("clear-preview-cache")
            if clearing { ProgressView(L10n.tr("ipad.3792ff146e8a")) }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text(L10n.tr("ipad.6a3f18619452")) } footer: {
            Text(L10n.tr("ipad.44d954285c71"))
        }
        .task { await refresh() }
        .confirmationDialog(L10n.tr("ipad.95f004f614ac"),isPresented: $confirm,titleVisibility: .visible) {
            Button(L10n.tr("ipad.d33461e6c0b6"),role: .destructive) {
                clearing = true
                Task {
                    do { try await model.clearPreviewCache(); await refresh() }
                    catch { self.error = error.localizedDescription }
                    clearing = false
                }
            }.accessibilityIdentifier("confirm-clear-cache")
        } message: { Text(L10n.tr("ipad.bb738ee7b310")) }
    }
    private func refresh() async {
        do { usage = try await model.engine.cacheUsage(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
#endif
