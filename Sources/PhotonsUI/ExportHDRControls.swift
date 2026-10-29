import AppKit
import SwiftUI
import PhotonsExport

/// 106 §A — the HDR row of 文件设置: a checkbox that is HEIC-only, plus a menu carrying the gain-map
/// type and the half-size switch. Every write lands in `model.preset.hdr`, the same struct the batch
/// is handed, so the row cannot disagree with the file.
struct ExportHDRRow: View {
    @Bindable var model: ExportSheetModel

    private var isHEIC: Bool { model.preset.format == .heic }
    private var locked: Bool { model.phase == .running || !isHEIC }

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: enabledBinding) {
                Text("HDR（HEIC + 增益图）")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isHEIC ? AnyShapeStyle(.secondary)
                                            : AnyShapeStyle(.tertiary))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .disabled(locked)
            Spacer(minLength: 8)
            Menu {
                Picker("增益图", selection: gainMapBinding) {
                    Text("ISO RGB").tag(HDRExport.GainMap.iso)
                    Text("ISO mono").tag(HDRExport.GainMap.mono)
                    Text("Apple").tag(HDRExport.GainMap.apple)
                }
                .pickerStyle(.inline)
                Toggle("半尺寸增益图", isOn: halfSizeBinding)
            } label: {
                HStack(spacing: 3) {
                    Text(model.preset.hdr?.gainMap.displayName ?? "ISO RGB")
                        .font(.system(size: 10))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
            }
            .menuStyle(.borderlessButton)
            .controlSize(.mini)
            .fixedSize()
            .disabled(model.phase == .running || !model.hdrEnabled)
            .help("增益图类型与尺寸")
        }
        .background(ExportLayoutProbeHost(kind: .hdrRow))
    }

    private var enabledBinding: Binding<Bool> {
        Binding(get: { model.hdrEnabled }, set: { model.setHDR($0) })
    }

    private var gainMapBinding: Binding<HDRExport.GainMap> {
        Binding(get: { model.hdrGainMap }, set: { model.hdrGainMap = $0 })
    }

    private var halfSizeBinding: Binding<Bool> {
        Binding(get: { model.hdrHalfSize }, set: { model.hdrHalfSize = $0 })
    }
}

/// 106 §B — the layout readback for the export sheet.
///
/// SwiftUI `Text` has no AppKit leaf and the accessibility tree is empty under `swift test`, so the
/// three things the task measures (where the results region ends, whether the empty prompt sits on
/// the footer's row, whether the form kept its height when the window grew) need one honest anchor
/// per region. Each probe is a transparent, hit-test-less `NSView` placed as the background of the
/// region itself, so its frame *is* the region's frame — not a constant read back from a constant.
final class ExportLayoutProbe: NSView {

    enum Kind: String {
        case form
        case hdrRow
        case results
        case footer
        case status
    }

    private(set) var kind: Kind = .form
    /// Rows the results region is showing. Zero means the empty state — the scroll view is not built.
    private(set) var rowCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) {
        fatalError("ExportLayoutProbe is created in code")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    func update(kind: Kind, rowCount: Int) {
        self.kind = kind
        self.rowCount = rowCount
    }
}

struct ExportLayoutProbeHost: NSViewRepresentable {
    var kind: ExportLayoutProbe.Kind
    var rowCount: Int = 0

    func makeNSView(context: Context) -> ExportLayoutProbe {
        let probe = ExportLayoutProbe()
        probe.update(kind: kind, rowCount: rowCount)
        return probe
    }

    func updateNSView(_ probe: ExportLayoutProbe, context: Context) {
        probe.update(kind: kind, rowCount: rowCount)
    }
}
