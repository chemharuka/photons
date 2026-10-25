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
        // edit whose values the encoder silently drops.
        value = Preset(name: value.name, groups: value.groups, edit: value.edit)
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
    /// the destination's other groups, its masks and its `showMaskID` are left alone. When the paste
    /// changes nothing (same values), `appendDevelop` commits nothing and `changed` is false — a
    /// paste is not an edit just because it was clicked.
    @discardableResult
    public func pasteSettings(_ snapshot: EditSnapshot, intoAsset id: String,
                              label: String = "Paste Settings") throws -> DevelopSaveResult {
        let current = try develop(forAsset: id)
        let merged = snapshot.applied(to: current)
        return try appendDevelop(merged, label: label, forAsset: id)
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
