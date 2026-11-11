//
//  main.swift
//  photons-hdr
//
//  Thin command line over `PhotonsExtensions.HDRMergeService`: the same code path a future UI
//  entry would take, so this is both the user-facing tool today and the proof that the service
//  works end to end.
//
//  MIT, like Photons. It spawns `hdrmerge-swift` (GPLv3) as a child process — nothing of that
//  project is linked here.
//

import Foundation
import PhotonsExtensions

func usage() -> String {
    """
    photons-hdr — merge bracketed RAW frames into one Bayer (CFA) DNG

    usage:
      photons-hdr merge [options] FRAME.dng FRAME.dng ...
        -o DIR              write into DIR (default: next to the first frame)
        --bits 16|32        bits per sample (default 16)
        --headroom N        container top = N× input white (default 4 = +2 stops, bit-exact)
        --feather N         mask feather radius (default 3)
        --compress          SOF3 lossless JPEG (121 MB → ~50 MB on 60 MP, bit-exact)
        --no-import         only write the file (default is also no-import: no library here)
        --json              print one JSON object on stdout
      photons-hdr capabilities [--json]
      photons-hdr inspect FRAME.dng...

    exit codes: 0 ok · 2 usage · 3 bad input · 4 incompatible frames · 5 write failed
    """
}

func fail(_ message: String, code: Int32, json: Bool, command: String) -> Never {
    if json {
        let obj: [String: Any] = ["ok": false, "command": command,
                                  "error": ["message": message]]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let argv = Array(CommandLine.arguments.dropFirst())
let command = argv.first ?? ""
let wantsJSON = argv.contains("--json")

switch command {
case "capabilities":
    let service = HDRMergeService()
    let tool: Any = service.client.map {
        ["path": $0.executableURL.path, "protocol": (try? $0.protocolVersion()) ?? -1] as [String: Any]
    } ?? NSNull()
    let payload: [String: Any] = ["ok": true, "command": "capabilities",
                                  "available": service.isAvailable, "tool": tool]
    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    if !service.isAvailable {
        FileHandle.standardError.write(Data("hdrmerge-swift not found\n".utf8))
        exit(3)
    }

case "inspect":
    let frames = argv.dropFirst().filter { !$0.hasPrefix("-") }
    guard !frames.isEmpty else { fail(usage(), code: 2, json: wantsJSON, command: command) }
    guard let client = HDRMergeService().client else {
        fail("hdrmerge-swift not found", code: 3, json: wantsJSON, command: command)
    }
    do {
        let infos = try client.inspect(frames.map { URL(fileURLWithPath: $0) })
        for info in infos {
            print("\(info.url.lastPathComponent)  \(info.width)x\(info.height)  "
                + "CFA \(info.cfaPattern.map { ["R","G","B","G2"][min($0, 3)] }.joined())  "
                + "black \(info.blackLevel.first ?? 0)  white \(info.whiteLevel)  "
                + "1/\(Int(1 / max(info.exposureTime, 1e-6)))s  ISO \(Int(info.iso))")
        }
    } catch {
        fail("\(error)", code: 3, json: wantsJSON, command: command)
    }

case "merge":
    var inputs: [String] = []
    var outputDirectory: URL?
    var json = wantsJSON
    let service = HDRMergeService()
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "-o":
            guard i + 1 < argv.count else { fail(usage(), code: 2, json: wantsJSON, command: command) }
            outputDirectory = URL(fileURLWithPath: argv[i + 1]); i += 2
        case "--bits":
            service.bits = Int(argv[i + 1]) ?? 16; i += 2
        case "--headroom":
            service.headroom = Double(argv[i + 1]) ?? 4; i += 2
        case "--feather":
            service.featherRadius = Int(argv[i + 1]) ?? 3; i += 2
        case "--compress":
            service.compress = true; i += 1
        case "--no-import":
            i += 1
        case "--json":
            json = true; i += 1
        default:
            inputs.append(argv[i]); i += 1
        }
    }
    guard inputs.count >= 2 else { fail(usage(), code: 2, json: json, command: command) }

    do {
        // A CLI run has no library: the merged DNG is written next to its sources and the user
        // imports it (or a future UI does).
        let outcome = try service.merge(inputs.map { URL(fileURLWithPath: $0) },
                                        outputDirectory: outputDirectory,
                                        progress: { line in
                                            if !json {
                                                FileHandle.standardError.write(Data((line + "\n").utf8))
                                            }
                                        })
        if json {
            let obj: [String: Any] = [
                "ok": true, "command": "merge",
                "output": outcome.output.path, "bytes": outcome.bytes,
                "width": outcome.width, "height": outcome.height,
                "frames": outcome.frameCount, "whiteLevel": outcome.whiteLevel,
                "compressed": service.compress,
                "metadataFrom": outcome.metadataFrom.path, "report": outcome.report,
            ]
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for line in outcome.report { print(line) }
            print("merged \(outcome.width)x\(outcome.height) from \(outcome.frameCount) frames")
            print("metadata from \(outcome.metadataFrom.lastPathComponent)")
            print("wrote \(outcome.output.path) (\(outcome.bytes) bytes)")
        }
    } catch let failure as HDRMergeService.Failure {
        let code: Int32
        switch failure.code {
        case "not_enough_frames", "geometry_mismatch": code = 4
        case "write_failed": code = 5
        default: code = 3
        }
        fail(failure.description, code: code, json: json, command: command)
    } catch {
        fail("\(error)", code: 3, json: json, command: command)
    }

default:
    print(usage())
    exit(command.isEmpty ? 2 : 2)
}
