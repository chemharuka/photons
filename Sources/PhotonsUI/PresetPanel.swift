import SwiftUI
import PhotonsCatalog
import PhotonsCore

/// The preset card: list, apply, create-from-this-photo, delete, make default.
///
/// A leaf view like `MaskListPanel` — it owns the *selection* and the name field (view state) and
/// nothing else. Every mutation goes through `CatalogSession`, which is what keeps the card, the
/// Develop ▸ 预设 menu and the undo stack describing the same library:
///
///   · **applying is one undo step.** The session merges the preset's groups into the live document
///     and commits once, so ⌘Z takes the whole look back in one press and the inspector's history
///     strip names it ("⌘Z 预设 Punch"). A preset is not a special kind of edit; it is an edit with
///     a name.
///   · **creating is a capture, not a copy of the file.** The fragment is the live document
///     projected onto the chosen groups (masks are never carried — `docs/xmp-mapping.md` §1.8).
public struct PresetPanel: View {
    @Bindable public var session: CatalogSession

    /// The row the buttons act on. Local on purpose: "which preset is highlighted in a list" is not
    /// library state, and putting it in the session would make ⌘Z's snapshot arguments depend on a
    /// hover.
    @State private var selection: String?
    @State private var newName: String = ""

    public init(session: CatalogSession) {
        self.session = session
    }

    private var records: [PresetRecord] { session.presetRecords }

    private var selectedRecord: PresetRecord? {
        guard let selection else { return nil }
        return records.first { $0.name == selection }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            list
            divider
            createRow
            if let error = session.lastPresetError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, WorkspaceLayout.cardInsetH)
        .padding(.vertical, WorkspaceLayout.cardInsetV)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Small widget container: glass here, matte everywhere else (§2b item 5).
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WorkspaceLayout.cardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onAppear {
            // Cheap and idempotent: the session caches the list, this makes the card agree with a
            // library another window (or the CLI) wrote to.
            session.reloadPresets()
            if selection == nil { selection = records.first?.name }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 6) {
            Text("预设")
                .font(.system(size: 11, weight: .bold))
            Text("\(records.count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 4)
            Button {
                if let name = selectedRecord?.name { session.applyPreset(named: name) }
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(selectedRecord == nil || session.anchorAsset == nil)
            .help("应用预设（一条开发历史，⌘Z 一次撤销）")
            Button {
                if let name = selectedRecord?.name {
                    session.setDefaultPreset(named: selectedRecord?.isDefault == true ? nil : name)
                }
            } label: {
                Image(systemName: selectedRecord?.isDefault == true ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(selectedRecord == nil)
            .help("设为默认预设")
            Button {
                if let name = selectedRecord?.name {
                    session.deletePreset(named: name)
                    selection = session.presetRecords.first?.name
                }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .disabled(selectedRecord == nil)
            .help("删除预设")
        }
    }

    // MARK: list

    @ViewBuilder private var list: some View {
        if records.isEmpty {
            Text("还没有预设。调好这张照片，然后在下面命名保存。")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 1) {
                ForEach(records, id: \.name) { record in
                    row(record)
                }
            }
        }
    }

    private func row(_ record: PresetRecord) -> some View {
        let isSelected = selection == record.name
        return HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3, height: 13)
            Text(record.name)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(groupSummary(record.preset.groups))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if record.isDefault {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isSelected ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        // Single click selects; double click applies. Two `onTapGesture`s instead of a simultaneous
        // gesture: a double-click must not also fire the single-click handler (and an apply on top
        // of an apply would be a second undo step for the same look).
        .onTapGesture(count: 2) {
            selection = record.name
            session.applyPreset(named: record.name)
        }
        .onTapGesture { selection = record.name }
        .help("双击应用")
    }

    /// "L C" style abbreviations: enough to tell a Light-only preset from a full look at a glance.
    private func groupSummary(_ groups: Set<PresetGroup>) -> String {
        let ordered = PresetGroup.ordered(groups)
        if ordered.count == PresetGroup.allCases.count { return "全部" }
        return ordered.map { group in
            switch group {
            case .geometry: return "G"
            case .light: return "L"
            case .curve: return "T"
            case .color: return "C"
            // 2026-10-28 (P0 色彩分级): "K" for 分级 (the letter C is taken by Color; "G" by geometry).
            case .colorGrading: return "K"
            case .detail: return "D"
            case .effects: return "E"
            }
        }.joined()
    }

    // MARK: create

    private var createRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("新预设名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.mini)
                    .font(.system(size: 10))
                    .onSubmit { create() }
                Button("从当前照片新建") { create() }
                    .controlSize(.mini)
                    .disabled(session.anchorAsset == nil
                              || newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(session.anchorAsset.map { "以 \($0.filename) 当前外观保存（不含蒙版）" }
                 ?? "未选择照片")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if session.createPresetFromCurrent(named: name) != nil {
            selection = name
            newName = ""
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
    }
}
