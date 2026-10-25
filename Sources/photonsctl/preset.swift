import Foundation
import PhotonsCatalog
import PhotonsCore

// MARK: - photonsctl preset … and the settings clipboard
//
//   photonsctl preset list    <pkg> [--json]
//   photonsctl preset save    <pkg> <name> --asset <id> [--groups light,curve] [--default]
//   photonsctl preset save    <pkg> <name> --from <preset.json> [--groups …] [--default]
//   photonsctl preset apply   <pkg> <name> --asset <id> [--label L] [--json]
//   photonsctl preset delete  <pkg> <name>
//   photonsctl preset rename  <pkg> <old> <new>
//   photonsctl preset default <pkg> <name> | --none
//
//   photonsctl library copy-settings  <pkg> --asset <id> [--out file.json]
//   photonsctl library paste-settings <pkg> --asset <id> --from <file.json|->
//
// Why a private parser: `Args.valueFlags` lives in `main.swift`, which this change does not own, so
// a `--asset <id>` pair would otherwise leave `<id>` behind as a positional. Parsing here (the same
// trick `develop.swift` uses) keeps the option set local to the feature and both spellings work.

struct PresetCLI {
    static let valueOptions: Set<String> = ["--asset", "--groups", "--from", "--label", "--out"]
    static let flagOptions: Set<String> = ["--default", "--json", "--none", "--quiet"]

    var positional: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let token = argv[i]
            if let eq = token.firstIndex(of: "="), token.hasPrefix("--") {
                let name = String(token[token.startIndex..<eq])
                if Self.valueOptions.contains(name) {
                    values[name] = String(token[token.index(after: eq)...])
                    i += 1
                    continue
                }
            }
            if Self.valueOptions.contains(token) {
                if i + 1 < argv.count { values[token] = argv[i + 1]; i += 2 } else { i += 1 }
                continue
            }
            if Self.flagOptions.contains(token) { flags.insert(token); i += 1; continue }
            if token.hasPrefix("--") { flags.insert(token); i += 1; continue }
            positional.append(token)
            i += 1
        }
    }

    func value(_ name: String) -> String? { values[name] }
    func has(_ name: String) -> Bool { flags.contains(name) }
}

func presetOpenCatalog(_ path: String) -> Catalog {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    do { return try Catalog.open(at: url) } catch { die("\(error.localizedDescription)") }
}

func presetJSON<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value), let s = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return s
}

func presetGroupsText(_ groups: Set<PresetGroup>) -> String {
    PresetGroup.ordered(groups).map(\.rawValue).joined(separator: ",")
}

// MARK: - preset subcommands

func cmdPreset(_ a: Args) throws {
    let cli = PresetCLI(Array(CommandLine.arguments.dropFirst()))
    guard cli.positional.count >= 2 else {
        die("preset needs a subcommand: list | save | apply | delete | rename | default")
    }
    let verb = cli.positional[1]
    guard cli.positional.count >= 3 else {
        die("preset \(verb) <pkg> …  (see `photonsctl` for usage)")
    }
    let catalog = presetOpenCatalog(cli.positional[2])

    switch verb {
    case "list":
        let records = try catalog.presetRecords()
        if cli.has("--json") {
            note(jsonLine(records.map { record -> [String: Any] in
                [
                    "name": record.name,
                    "groups": PresetGroup.ordered(record.groups).map(\.rawValue),
                    "default": record.isDefault,
                    "fields": EditSnapshot.capture(record.edit).fieldCount,
                    "createdAt": record.createdAt,
                    "updatedAt": record.updatedAt,
                ]
            }))
        } else {
            if records.isEmpty { note("presets    none") }
            for record in records {
                let mark = record.isDefault ? "*" : " "
                let fields = EditSnapshot.capture(record.edit).fieldCount
                note("\(mark) \(record.name)  [\(presetGroupsText(record.groups))]  \(fields) field"
                     + (fields == 1 ? "" : "s"))
            }
        }
        if catalog.presetDecodeFailures > 0 {
            err("warning: \(catalog.presetDecodeFailures) preset row(s) did not decode "
                + "(newer schemaVersion or damaged bytes); they were left out of the list")
        }

    case "save":
        guard cli.positional.count >= 4 else { die("preset save <pkg> <name> --asset <id>") }
        let name = cli.positional[3]
        var groups: Set<PresetGroup>?
        if let raw = cli.value("--groups") {
            let parsed = PresetGroup.parse(raw)
            guard parsed.unknown.isEmpty else {
                die("unknown preset group(s): \(parsed.unknown.joined(separator: ", "))"
                    + " (known: \(PresetGroup.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            groups = parsed.groups
        }

        let preset: Preset
        if let from = cli.value("--from") {
            let url = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { die("no such file: \(url.path)") }
            var loaded: Preset
            do { loaded = try Preset.load(from: url) } catch { die("could not read \(url.lastPathComponent): \(error.localizedDescription)") }
            loaded.name = name
            if let groups {
                // Narrowing only: a group the file does not carry has no values to apply, and a
                // preset with an empty fragment for a listed group would silently reset that panel.
                let missing = groups.subtracting(loaded.groups)
                guard missing.isEmpty else {
                    die("\(url.lastPathComponent) does not carry: "
                        + "\(PresetGroup.ordered(missing).map(\.rawValue).joined(separator: ", "))"
                        + " (it has: \(presetGroupsText(loaded.groups)))")
                }
                loaded.groups = groups
            }
            loaded.schemaVersion = Preset.currentSchemaVersion
            preset = loaded
        } else {
            guard let asset = cli.value("--asset") else {
                die("preset save needs --asset <id> (capture from a photo) or --from <preset.json>")
            }
            let state = try catalog.developState(forAsset: asset)
            if state.developVersion == 0 { die("no asset with id \(asset)") }
            preset = Preset(name: name, from: state.edit,
                            groups: groups ?? Set(PresetGroup.allCases))
        }

        let record = try catalog.savePreset(preset, makeDefault: cli.has("--default"))
        let fields = EditSnapshot.capture(record.edit).fieldCount
        if cli.has("--json") {
            note(jsonLine([
                "name": record.name,
                "groups": PresetGroup.ordered(record.groups).map(\.rawValue),
                "default": record.isDefault,
                "fields": fields,
                "createdAt": record.createdAt,
                "updatedAt": record.updatedAt,
            ]))
        } else {
            note("preset     \(record.name)  [\(presetGroupsText(record.groups))]"
                 + "  \(fields) field\(fields == 1 ? "" : "s")"
                 + (record.isDefault ? "  (default)" : ""))
            note("           masks are never part of a preset")
        }

    case "apply":
        guard cli.positional.count >= 4 else { die("preset apply <pkg> <name> --asset <id>") }
        let name = cli.positional[3]
        guard let asset = cli.value("--asset") else { die("preset apply needs --asset <id>") }
        let record = try catalog.requirePreset(named: name)
        let saved = try catalog.applyPreset(record.preset, toAsset: asset, label: cli.value("--label"))
        if cli.has("--json") {
            note(jsonLine([
                "asset": asset,
                "preset": record.name,
                "developVersion": saved.developVersion,
                "seq": saved.historySeq,
                "rows": saved.historyRows,
                "changed": saved.changed,
            ]))
        } else {
            note("preset     \(record.name) → \(asset)")
            note("develop    v\(saved.developVersion)\(saved.changed ? "" : "  (unchanged)")")
            note("history    \(saved.historyRows) rows, cursor seq \(saved.historySeq)"
                 + (saved.changed ? "  (one undo step)" : "  (nothing to apply)"))
        }

    case "delete":
        guard cli.positional.count >= 4 else { die("preset delete <pkg> <name>") }
        let name = cli.positional[3]
        let removed = try catalog.deletePreset(named: name)
        if cli.has("--json") {
            note(jsonLine(["name": name, "deleted": removed]))
        } else {
            note(removed ? "deleted    \(name)" : "no preset named \(name)")
        }
        if !removed { exit(1) }

    case "rename":
        guard cli.positional.count >= 5 else { die("preset rename <pkg> <old> <new>") }
        let record = try catalog.renamePreset(named: cli.positional[3], to: cli.positional[4])
        if cli.has("--json") {
            note(jsonLine(["name": record.name, "default": record.isDefault]))
        } else {
            note("renamed    \(cli.positional[3]) → \(record.name)"
                 + (record.isDefault ? "  (default)" : ""))
        }

    case "default":
        if cli.has("--none") {
            _ = try catalog.setDefaultPreset(named: nil)
            note("default    cleared")
            return
        }
        guard cli.positional.count >= 4 else { die("preset default <pkg> <name> | --none") }
        let record = try catalog.setDefaultPreset(named: cli.positional[3])
        note("default    \(record?.name ?? "")")

    default:
        die("unknown preset subcommand '\(verb)' (list|save|apply|delete|rename|default)")
    }
}

// MARK: - library copy-settings / paste-settings

func cmdLibraryCopySettings() throws {
    let cli = PresetCLI(Array(CommandLine.arguments.dropFirst()))
    guard cli.positional.count >= 3 else { die("library copy-settings <pkg> --asset <id> [--out file]") }
    guard let asset = cli.value("--asset") else { die("library copy-settings needs --asset <id>") }
    let catalog = presetOpenCatalog(cli.positional[2])
    let state = try catalog.developState(forAsset: asset)
    if state.developVersion == 0 { die("no asset with id \(asset)") }

    let snapshot = EditSnapshot.capture(state.edit)
    let json = presetJSON(snapshot)

    if let out = cli.value("--out") {
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        do { try Data(json.utf8).write(to: url, options: .atomic) } catch {
            die("could not write \(url.path): \(error.localizedDescription)")
        }
        note("copied     \(snapshot.fieldCount) of \(EditSnapshot.fullDocumentFieldCount) fields"
             + "  → \(url.path)")
    } else {
        // stdout stays pure JSON so `copy-settings … > s.json` pipes into `paste-settings --from`.
        note(json)
        err("copied     \(snapshot.fieldCount) of \(EditSnapshot.fullDocumentFieldCount) fields"
            + "  groups \(snapshot.groups.isEmpty ? "none" : RenderGroup.allCases.filter { snapshot.groups.contains($0) }.map(\.displayName).joined(separator: ", "))"
            + "  masks never copied")
    }
}

func cmdLibraryPasteSettings() throws {
    let cli = PresetCLI(Array(CommandLine.arguments.dropFirst()))
    guard cli.positional.count >= 3 else { die("library paste-settings <pkg> --asset <id> --from <file|->") }
    guard let asset = cli.value("--asset") else { die("library paste-settings needs --asset <id>") }
    guard let from = cli.value("--from") else { die("library paste-settings needs --from <file.json|->") }

    let data: Data
    if from == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        let url = URL(fileURLWithPath: (from as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { die("no such file: \(url.path)") }
        data = try Data(contentsOf: url)
    }
    let snapshot: EditSnapshot
    do { snapshot = try JSONDecoder().decode(EditSnapshot.self, from: data) } catch {
        die("could not read the settings payload: \(error.localizedDescription)")
    }

    let catalog = presetOpenCatalog(cli.positional[2])
    let state = try catalog.developState(forAsset: asset)
    if state.developVersion == 0 { die("no asset with id \(asset)") }
    let saved = try catalog.pasteSettings(snapshot, intoAsset: asset)

    if cli.has("--json") {
        note(jsonLine([
            "asset": asset,
            "fields": snapshot.fieldCount,
            "developVersion": saved.developVersion,
            "seq": saved.historySeq,
            "rows": saved.historyRows,
            "changed": saved.changed,
        ]))
    } else {
        note("pasted     \(snapshot.fieldCount) field\(snapshot.fieldCount == 1 ? "" : "s")")
        note("develop    v\(saved.developVersion)\(saved.changed ? "" : "  (unchanged)")")
        note("history    \(saved.historyRows) rows, cursor seq \(saved.historySeq)"
             + (saved.changed ? "  (one undo step)" : "  (nothing to paste)"))
    }
}
