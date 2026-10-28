import Foundation
import GRDB
import PhotonsCore

// MARK: - Presets and the settings clipboard (M5)
//
// Two features, one file, because they answer the same question — "carry a *subset* of an edit from
// one photo to another" — and sharing the code is what keeps them consistent:
//
//   presets              a named subset that lives in the library, applied by name
//   copy / paste         an unnamed subset that lives in the clipboard, applied once
//
// Storage rules, each with a test:
//
//  1. **A preset is a preset envelope, not a document.** `presets.develop_json` is
//     `Catalog.encode(_: Preset)`, the same sorted-keys encoder `assets.develop_json` uses, so a
//     preset can be dumped to a file and read back byte for byte.
//  2. **Applying is one undo step.** `applyPreset` and `pasteSettings` both go through
//     `appendDevelop`, which is one `EditHistory.commit` → one `asset_history` row. A preset that
//     changed five panels must not need five undos.
//  3. **The destination keeps what the payload does not carry.** Masks in particular: a preset or
//     a clipboard snapshot carries no masks at all, and the merge never writes `masks` or
//     `showMaskID` (docs/xmp-mapping.md §1.8 — mask geometry is frame-relative and not portable).
//  4. **Names are unique case-insensitively**, enforced by a `COLLATE NOCASE` unique index, because
//     "Punch" and "punch" in one menu is a bug report waiting to happen.

// MARK: - value types

/// A stored preset: the envelope plus the row facts.
public struct PresetRecord: Sendable, Equatable {
    public var id: String
    public var preset: Preset
    public var isDefault: Bool
    public var createdAt: String
    public var updatedAt: String

    public init(id: String, preset: Preset, isDefault: Bool, createdAt: String, updatedAt: String) {
        self.id = id
        self.preset = preset
        self.isDefault = isDefault
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var name: String { preset.name }
    public var groups: Set<PresetGroup> { preset.groups }
    public var edit: EditModel { preset.edit }
}

/// What one 粘贴设置 actually did to one photo.
///
/// The report exists so the caller can say 「3 张：2 张改动、1 张本来就是这样」 and so a test can assert
/// *which leaves* moved (`fields`, from the same `EditHistory.changedFields` the history panel
/// draws) instead of comparing whole documents and guessing. `requiresDecode` is the payload's own
/// answer — for the anchor photo it is what makes the loupe develop again
/// (`EditModel.splitFrom(_:) == .decode`); for any other photo nothing is on screen to re-develop.
public struct SettingsPasteReport: Sendable, Equatable {
    public var assetID: String
    /// False = nothing was written: the narrowed payload was empty, or the photo already had it.
    public var changed: Bool
    /// The leaves that moved, in `HistoryFields` order.
    public var fields: [FieldChange]
    /// The sections the narrowed payload carried (not the ones chosen — empty ones drop out).
    public var sections: Set<EditSnapshotSection>
    /// Would the destination need a new decode (white balance), or only a re-render?
    public var requiresDecode: Bool
    /// Rows in that asset's `asset_history` after the write, or nil when nothing was written.
    public var historyRows: Int?

    public init(assetID: String, changed: Bool, fields: [FieldChange],
                sections: Set<EditSnapshotSection>, requiresDecode: Bool, historyRows: Int?) {
        self.assetID = assetID
        self.changed = changed
        self.fields = fields
        self.sections = sections
        self.requiresDecode = requiresDecode
        self.historyRows = historyRows
    }

    /// 「曝光 +2、对比 +10」 — the one line a test failure and a status bar can both read.
    public var summary: String {
        changed ? fields.map(\.summary).joined(separator: "、") : "无改动"
    }
}

public enum PresetStoreError: LocalizedError {
    case noSuchPreset(String)
    /// A row whose blob is not a preset this build can read (empty, not JSON, or a version it does
    /// not know). Reported, never silently overwritten: the bytes stay in the row.
    case undecodablePreset(name: String, reason: String)
    case duplicateName(String)

    public var errorDescription: String? {
        switch self {
        case .noSuchPreset(let name): return "no preset named '\(name)'"
        case .undecodablePreset(let name, let reason):
            return "preset '\(name)' could not be read: \(reason)"
        case .duplicateName(let name): return "a preset named '\(name)' already exists"
        }
    }
}

// MARK: - storage

extension Catalog {

    /// Canonical bytes for `presets.develop_json`. Same encoder as the develop document; the preset
    /// envelope carries its own `schemaVersion`, so a future build can refuse it by version instead
    /// of guessing which fields are missing.
    public static func encodePreset(_ preset: Preset) throws -> String {
        try Catalog.encode(preset)
    }

    /// Every readable preset, default first, then by name.
    ///
    /// A row this build cannot read (newer `schemaVersion`, hand-edited junk) is **left out of the
    /// list and counted**, not thrown: one bad row must not empty the preset menu. The bytes stay in
    /// the table so a newer build — or a human with `sqlite3` — can still recover them.
    public func presetRecords() throws -> [PresetRecord] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM presets ORDER BY is_default DESC, name COLLATE NOCASE")
        }
        var out: [PresetRecord] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            do {
                out.append(try Self.presetRecord(row))
            } catch {
                presetFailureCounter.increment()
            }
        }
        return out
    }

    /// One preset by name (case-insensitive), or nil. Throws when the row exists but does not decode
    /// — the caller asked for *that* preset, so silence would be a lie.
    public func presetRecord(named name: String) throws -> PresetRecord? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM presets WHERE name = ? COLLATE NOCASE", arguments: [trimmed])
        }
        guard let row else { return nil }
        return try Self.presetRecord(row)
    }

    public func presetRecord(id: String) throws -> PresetRecord? {
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM presets WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        return try Self.presetRecord(row)
    }

    /// `presetRecord(named:)` or throw — what the CLI and `applyPreset(named:)` want.
    public func requirePreset(named name: String) throws -> PresetRecord {
        guard let record = try presetRecord(named: name) else {
            throw PresetStoreError.noSuchPreset(name)
        }
        return record
    }

    public func defaultPresetRecord() throws -> PresetRecord? {
        let row = try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM presets WHERE is_default = 1")
        }
        guard let row else { return nil }
        return try Self.presetRecord(row)
    }

    /// Create or update **by name**. Saving "Punch" twice updates the same row (same id, same
    /// created_at) instead of growing a second menu entry that looks identical.
    @discardableResult
    public func savePreset(_ preset: Preset, makeDefault: Bool = false) throws -> PresetRecord {
        var value = preset
        value.name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.name.isEmpty else { throw PresetError.emptyName }
        guard !value.groups.isEmpty else { throw PresetError.noGroups }
        // Re-project through the public initializer so `record.edit` is exactly what the blob
        // carries. A caller that mutated `groups` after capturing would otherwise hand back an
        // edit whose values the encoder silently drops. `sections` (081) travels through: it is what
        // makes a card-scoped preset apply field-by-field instead of replacing a whole group.
        value = Preset(name: value.name, groups: value.groups, edit: value.edit,
                       sections: value.sections)
        let blob = try Self.encodePreset(value)
        let stamp = ISO8601.now()

        return try dbQueue.write { db in
            if let existing = try Row.fetchOne(db,
                                              sql: "SELECT id FROM presets WHERE name = ? COLLATE NOCASE",
                                              arguments: [value.name]) {
                let id: String = existing["id"]
                try db.execute(sql: """
                    UPDATE presets SET name = ?, develop_json = ?, updated_at = ? WHERE id = ?
                    """, arguments: [value.name, blob, stamp, id])
                if makeDefault {
                    try Self.clearDefaultPreset(db, except: id)
                    try db.execute(sql: "UPDATE presets SET is_default = 1 WHERE id = ?", arguments: [id])
                }
                let isDefault = try Bool.fetchOne(db,
                                                  sql: "SELECT is_default FROM presets WHERE id = ?",
                                                  arguments: [id]) ?? false
                let createdAt = try String.fetchOne(db,
                                                    sql: "SELECT created_at FROM presets WHERE id = ?",
                                                    arguments: [id]) ?? stamp
                return PresetRecord(id: id, preset: value, isDefault: isDefault,
                                    createdAt: createdAt, updatedAt: stamp)
            }

            let id = UUID().uuidString
            if makeDefault { try Self.clearDefaultPreset(db, except: id) }
            try db.execute(sql: """
                INSERT INTO presets(id, name, develop_json, is_default, created_at, updated_at)
                VALUES(?, ?, ?, ?, ?, ?)
                """, arguments: [id, value.name, blob, makeDefault ? 1 : 0, stamp, stamp])
            return PresetRecord(id: id, preset: value, isDefault: makeDefault,
                                createdAt: stamp, updatedAt: stamp)
        }
    }

    /// Rename in place. The envelope's own `name` is rewritten too — the row name is a mirror of it,
    /// and a preset exported before the rename must not disagree with the menu.
    @discardableResult
    public func renamePreset(named name: String, to newName: String) throws -> PresetRecord {
        var record = try requirePreset(named: name)
        let target = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw PresetError.emptyName }
        // Case-insensitively identical is not a rename (and must not trip the unique index).
        if target.compare(name, options: .caseInsensitive) != .orderedSame,
           try presetRecord(named: target) != nil {
            throw PresetStoreError.duplicateName(target)
        }
        record.preset.name = target
        let blob = try Self.encodePreset(record.preset)
        let stamp = ISO8601.now()
        let id = record.id
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE presets SET name = ?, develop_json = ?, updated_at = ? WHERE id = ?",
                           arguments: [target, blob, stamp, id])
        }
        record.updatedAt = stamp
        return record
    }

    /// Remove a preset. Returns false when there was nothing by that name.
    @discardableResult
    public func deletePreset(named name: String) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM presets WHERE name = ? COLLATE NOCASE", arguments: [trimmed])
            return db.changesCount > 0
        }
    }

    /// Make one preset the library default, or (`nil`) clear the default.
    ///
    /// The swap clears the previous default inside the same transaction: the partial unique index on
    /// `is_default = 1` would otherwise turn "make this the default" into a constraint error.
    @discardableResult
    public func setDefaultPreset(named name: String?) throws -> PresetRecord? {
        guard let name else {
            try dbQueue.write { db in try Self.clearDefaultPreset(db, except: nil) }
            return nil
        }
        let record = try requirePreset(named: name)
        try dbQueue.write { db in
            try Self.clearDefaultPreset(db, except: record.id)
            try db.execute(sql: "UPDATE presets SET is_default = 1, updated_at = ? WHERE id = ?",
                           arguments: [ISO8601.now(), record.id])
        }
        return try presetRecord(id: record.id)
    }

    /// Remove a preset's default flag without touching any other preset.
    @discardableResult
    public func clearDefaultPreset(named name: String) throws -> PresetRecord? {
        let record = try requirePreset(named: name)
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE presets SET is_default = 0 WHERE id = ?", arguments: [record.id])
        }
        return try presetRecord(id: record.id)
    }

    // MARK: applying

    /// Apply a preset to one asset: **one** history row, whatever the preset covers.
    @discardableResult
    public func applyPreset(named name: String, toAsset id: String,
                            label: String? = nil) throws -> DevelopSaveResult {
        let record = try requirePreset(named: name)
        return try applyPreset(record.preset, toAsset: id, label: label)
    }

    @discardableResult
    public func applyPreset(_ preset: Preset, toAsset id: String,
                            label: String? = nil) throws -> DevelopSaveResult {
        let current = try develop(forAsset: id)
        let merged = preset.apply(to: current)
        return try appendDevelop(merged, label: label ?? "Preset: \(preset.name)", forAsset: id)
    }

    // MARK: copy / paste settings

    /// The sparse clipboard payload for one asset: non-default fields only, never masks.
    public func copySettings(fromAsset id: String) throws -> EditSnapshot {
        EditSnapshot.capture(try develop(forAsset: id))
    }

    /// Merge a clipboard payload into one asset, as **one** undo step.
    ///
    /// The merge is `EditSnapshot.applied(to:)`, which writes only the fields the payload carries:
    /// the destination's other groups and its `showMaskID` are left alone, and its **masks are kept**
    /// — a payload's masks are *appended*, not substituted (P1-5). `destinationAspect` is the
    /// `W/H` of this asset's frame, which is what re-anchors a carried mask; `nil` copies the
    /// normalised coordinates as-is. When the paste changes nothing (same values), `appendDevelop`
    /// commits nothing and `changed` is false — a paste is not an edit just because it was clicked.
    @discardableResult
    public func pasteSettings(_ snapshot: EditSnapshot, intoAsset id: String,
                              label: String = "Paste Settings",
                              destinationAspect: Double? = nil) throws -> DevelopSaveResult {
        let current = try develop(forAsset: id)
        let merged = snapshot.applied(to: current, destinationAspect: destinationAspect)
        return try appendDevelop(merged, label: label, forAsset: id)
    }

    /// 派单 078 P0-7 — paste **a chosen subset of sections**, reporting what moved.
    ///
    /// Same merge, one narrowing step in front of it: `snapshot.filtered(to:)` drops every leaf the
    /// user did not check, and the merge then cannot read (or write) the sections it dropped. So
    /// 「只粘曝光 + 曲线」 leaves the destination's white balance — and its crop, colour, masks — bit
    /// for bit, which is what the field-by-field assertions check. Checking 「蒙版」 is the mirror
    /// image of that: the mask list is appended and **nothing else in the document moves** (P1-5).
    ///
    /// `changed == false` covers three honest no-ops: the narrowed payload is empty, the destination
    /// already held those values, or the blob was already canonical. None of them grows the stack.
    ///
    /// `destinationAspect` (P1-5) is `W/H` of this asset's own frame; the caller is the only one who
    /// can know it (a document does not store its pixel size). `nil` copies mask coordinates as-is.
    @discardableResult
    public func pasteSettings(_ snapshot: EditSnapshot,
                              intoAsset id: String,
                              sections: Set<EditSnapshotSection>,
                              label: String = "粘贴设置",
                              destinationAspect: Double? = nil) throws -> SettingsPasteReport {
        let payload = snapshot.filtered(to: sections)
        let current = try develop(forAsset: id)
        guard !payload.isEmpty else {
            return SettingsPasteReport(assetID: id, changed: false, fields: [],
                                       sections: [], requiresDecode: false, historyRows: nil)
        }
        let merged = payload.applied(to: current, destinationAspect: destinationAspect)
        let fields = EditHistory.changedFields(between: current, and: merged)
        guard !fields.isEmpty else {
            // Nothing moved: do not call `appendDevelop` at all, so a paste that equals what the
            // photo already had cannot bump a version, a row or a seq.
            return SettingsPasteReport(assetID: id, changed: false, fields: [],
                                       sections: payload.sections,
                                       requiresDecode: payload.requiresDecode, historyRows: nil)
        }
        let saved = try appendDevelop(merged, label: label, forAsset: id)
        return SettingsPasteReport(assetID: id, changed: saved.changed, fields: fields,
                                   sections: payload.sections,
                                   requiresDecode: payload.requiresDecode,
                                   historyRows: saved.historyRows)
    }

    /// Paste into several assets — **one history row per asset**, in that asset's own stack.
    ///
    /// Not one transaction for the batch: a paste onto three photos is three edits in three
    /// timelines, and ⌘Z on photo B must take back photo B's paste only. A per-asset failure is
    /// reported as a thrown error from that asset, and the assets before it keep their rows (a
    /// half-applied batch is visible in the reports the caller already has).
    @discardableResult
    public func pasteSettings(_ snapshot: EditSnapshot,
                              intoAssets ids: [String],
                              sections: Set<EditSnapshotSection>,
                              label: String = "粘贴设置",
                              destinationAspect: (String) -> Double? = { _ in nil }) throws -> [SettingsPasteReport] {
        try ids.map {
            try pasteSettings(snapshot, intoAsset: $0, sections: sections, label: label,
                              destinationAspect: destinationAspect($0))
        }
    }


    // MARK: rows

    static func presetRecord(_ row: Row) throws -> PresetRecord {
        let name: String = row["name"]
        let blob: String = row["develop_json"]
        let trimmed = blob.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PresetStoreError.undecodablePreset(name: name, reason: "empty blob")
        }
        let preset: Preset
        do {
            preset = try JSONDecoder().decode(Preset.self, from: Data(trimmed.utf8))
        } catch let e as PresetError {
            throw e
        } catch {
            throw PresetStoreError.undecodablePreset(name: name, reason: "\(error)")
        }
        return PresetRecord(id: row["id"],
                            preset: preset,
                            isDefault: row["is_default"],
                            createdAt: row["created_at"],
                            updatedAt: row["updated_at"])
    }

    private static func clearDefaultPreset(_ db: Database, except id: String?) throws {
        if let id {
            try db.execute(sql: "UPDATE presets SET is_default = 0 WHERE id <> ?", arguments: [id])
        } else {
            try db.execute(sql: "UPDATE presets SET is_default = 0")
        }
    }
}
