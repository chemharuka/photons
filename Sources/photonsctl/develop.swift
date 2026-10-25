import Foundation
import PhotonsCatalog
import PhotonsCore

// MARK: - photonsctl library develop get | set | history
//
// The catalog is the document truth (D9) and there is no UI save path yet, so these three commands
// are how an edit is written into a library and read back out of it:
//
//   photonsctl library develop get     <pkg> --asset <id>                  # the document, as JSON
//   photonsctl library develop set     <pkg> --asset <id> --edit <file>   # append + persist
//   photonsctl library develop history <pkg> --asset <id>                  # the snapshot stack
//
// `get` writes the document to stdout and the bookkeeping to stderr, so `get > d.json` pipes straight
// back into `set --edit d.json`.

/// `--asset` and `--label` are read off `CommandLine.arguments` directly.
///
/// `Args.valueFlags` lives in `main.swift`, which this change deliberately does not touch (parallel
/// work owns it); an unknown `--flag value` pair would otherwise leave the value behind as a
/// positional. Positions are still accepted as a fallback so both spellings work.
func developOption(_ name: String) -> String? {
    let argv = Array(CommandLine.arguments.dropFirst())
    var i = 0
    while i < argv.count {
        let token = argv[i]
        if token == name, i + 1 < argv.count { return argv[i + 1] }
        if token.hasPrefix(name + "=") { return String(token.dropFirst(name.count + 1)) }
        i += 1
    }
    return nil
}

func developAssetID(_ a: Args) -> String {
    if let v = developOption("--asset"), !v.isEmpty { return v }
    if a.positional.count >= 4 { return a.positional[3] }
    die("library develop needs --asset <id>")
}

func developJSONValue(_ json: String) -> Any {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) else { return json }
    return object
}

func developPretty(_ edit: EditModel) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(edit), let s = String(data: data, encoding: .utf8) else { return "{}" }
    return s
}

func developISO(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    f.timeZone = TimeZone(secondsFromGMT: 0)
    return f.string(from: date)
}

func cmdLibraryDevelop(_ a: Args) throws {
    guard a.positional.count >= 3 else {
        die("library develop <get|set|history> <pkg> --asset <id>")
    }
    let verb = a.positional[1]

    switch verb {
    case "get":
        let catalog = openLibrary(a, index: 2)
        let id = developAssetID(a)
        let state = try catalog.developState(forAsset: id)
        let blob = (try? Catalog.encode(state.edit)) ?? "{}"

        if a.has("--json") {
            note(jsonLine([
                "asset": id,
                "developVersion": state.developVersion,
                "editTime": state.editTime ?? "",
                "historyEnd": state.historyEnd,
                "recovered": state.recovered,
                "develop": developJSONValue(blob),
            ]))
        } else {
            // stdout stays pure JSON so it can be fed back to `set --edit`.
            note(developPretty(state.edit))
        }
        err("develop    v\(state.developVersion)  history_end \(state.historyEnd)"
            + "  \(state.editTime ?? "never written")")
        if state.recovered {
            err("warning: stored develop document did not decode; read as .neutral "
                + "(original bytes kept in develop_quarantine)")
            err("failures   \(catalog.developDecodeFailures)")
        }
        if state.developVersion == 0 { die("no asset with id \(id)") }

    case "set":
        let catalog = openLibrary(a, index: 2)
        let id = developAssetID(a)
        guard let path = a.value("--edit") else {
            die("library develop set needs --edit <file.json>  (see `library develop get`)")
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else { die("no such edit file: \(url.path)") }
        let edit: EditModel
        do { edit = try EditModel.load(from: url) } catch {
            die("could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }

        var history = try catalog.editHistory(forAsset: id)
        if history.isEmpty {
            history = EditHistory(baseline: try catalog.develop(forAsset: id), label: "Original")
        }
        let appended = history.commit(edit, label: developOption("--label") ?? "")
        let saved = try catalog.saveDevelop(edit, history: history, forAsset: id)

        if a.has("--json") {
            note(jsonLine([
                "asset": id,
                "developVersion": saved.developVersion,
                "seq": saved.historySeq,
                "rows": saved.historyRows,
                "changed": saved.changed,
                "appended": appended != nil,
                "editTime": saved.editTime ?? "",
            ]))
        } else {
            let mark = saved.changed ? "" : "  (unchanged)"
            let editTime = saved.editTime ?? ""
            note("asset      \(id)")
            note("develop    v\(saved.developVersion)\(mark)  \(editTime)")
            if let appended {
                note("history    \(saved.historyRows) rows, cursor seq \(saved.historySeq)  +\(appended.label)")
            } else {
                note("history    \(saved.historyRows) rows, cursor seq \(saved.historySeq)"
                     + "  (identical document, no new snapshot)")
            }
        }

    case "history":
        let catalog = openLibrary(a, index: 2)
        let id = developAssetID(a)
        let state = try catalog.developState(forAsset: id)
        let rows = try catalog.historyRows(forAsset: id)
        // `history_end` = 0 means "no write yet"; the effective cursor is then the tip, which is what
        // `EditHistory(rows:cursorSeq:)` does with a cursor that names no row.
        let cursor = state.historyEnd == 0 ? (rows.last?.seq ?? 0) : state.historyEnd

        if a.has("--json") {
            note(jsonLine([
                "asset": id,
                "historyEnd": cursor,
                "rows": rows.map { snap -> [String: Any] in
                    [
                        "seq": snap.seq,
                        "label": snap.label,
                        "createdAt": developISO(snap.createdAt),
                        "current": snap.seq == cursor,
                        "develop": developJSONValue((try? Catalog.encode(snap.edit)) ?? "{}"),
                    ]
                },
            ]))
        } else {
            note("asset      \(id)   cursor seq \(cursor)   \(rows.count) rows")
            for snap in rows {
                let mark = snap.seq == cursor ? "▶" : " "
                note("\(mark) \(String(format: "%4d", snap.seq))  \(developISO(snap.createdAt))  \(snap.label)")
            }
        }
        if catalog.developDecodeFailures > 0 {
            err("warning: \(catalog.developDecodeFailures) develop blob(s) failed to decode "
                + "(see `sqlite3 <pkg>/library.db 'SELECT * FROM develop_quarantine'`)")
        }

    default:
        die("unknown develop verb '\(verb)' (get|set|history)")
    }
}
