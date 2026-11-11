# Host integration protocol (v1)

`hdrmerge-swift` is designed to be driven as a **child process** by another app.
Nothing is linked: the host spawns the binary, passes paths, reads JSON. That
keeps the GPLv3 boundary a plain aggregate (see `LICENSE-SCOPE.md`).

## Contract

* **stdout**: exactly **one JSON object**, newline-terminated, and nothing else —
  and only when `--json` is passed. Without `--json` the output is human prose
  and must not be parsed.
* **stderr**: diagnostics (`hdrmerge-swift: …`) plus, with `--progress`, one
  JSON event per line (NDJSON). A host may ignore stderr entirely.
* **exit code**: `0` ok · `2` usage · `3` bad input · `4` incompatible frames ·
  `5` write failed · `6` internal. The JSON `ok` field and the exit code always
  agree; the `error.code` string is the stable key to branch on (never the
  message text).
* **atomicity**: the output DNG is written to a sibling `.<name>.<pid>.tmp` and
  `rename`d into place. If the process dies mid-merge there is no partial DNG —
  only a stray temp file, which is safe to delete.
* The tool never prompts, never reads stdin, never needs a terminal.

## Commands

### `capabilities --json`

```json
{"ok":true,"command":"capabilities",
 "tool":{"name":"hdrmerge-swift","protocol":1,"version":"0.2.0"},
 "commands":["inspect","merge","decode","synth","capabilities"],
 "features":["inspect","merge","decode-pgm","ndjson-progress","atomic-write",
             "headroom","metadata-passthrough"],
 "defaults":{"bits":16,"headroom":1.0,"feather":3},
 "limits":{"inputFormats":["DNG (CFA), photometric 32803, compression 1 or 7"],
           "maxFrames":32}}
```

Call this first, once per launch: match `tool.protocol` against what the host
understands, and treat an unknown `protocol` as "too new".

### `merge --json -o OUT [options] [--] IN1 IN2 …`

```
-o PATH              output DNG (required)
-b 16|32             bits per sample; 16 default, 32 = float DNG
--headroom N         container top = N × input white level.
                     16-bit + 4 is bit-exact for the input scale and leaves
                     +2 stops of highlight room (WhiteLevel becomes 65535).
--feather N          mask feather radius (default 3)
--white N            override the detected saturation level
--metadata-from PATH copy EXIF/DNG metadata from this frame instead of the
                     least exposed one
--progress           NDJSON progress on stderr
--                   stop option parsing (paths starting with '-')
```

Success payload:

```json
{"ok":true,"command":"merge",
 "output":"/path/out.dng","bytes":121229748,
 "width":9532,"height":6342,"frames":3,"bits":16,"headroom":4,
 "whiteLevel":65535,"blackLevel":512,"cfaPattern":[0,1,1,2],
 "offsets":[{"x":-4,"y":0},{"x":-2,"y":-2},{"x":0,"y":-2}],
 "metadataFrom":"/path/IN1.dng",
 "report":["white level 16383, saturation threshold 15712","…"],
 "tool":{…}}
```

`width/height` are the merged canvas (the intersection of the aligned frames,
so usually a few pixels smaller than the inputs); `offsets` are in input order
and are what the host needs if it wants to map input coordinates to output.

### `inspect --json FILE…`

```json
{"ok":true,"command":"inspect","frames":[
  {"path":"…","fileName":"A.dng","make":"LEICA CAMERA AG","model":"LEICA SL3",
   "rawWidth":9536,"rawHeight":6344,"width":9536,"height":6344,
   "cfaPattern":[0,1,1,2],"cfaRows":2,"cfaCols":2,
   "blackLevel":[512,512,512,512],"whiteLevel":16383,
   "exposureTime":0.0025,"iso":100,
   "asShotNeutral":[0.400783,1,0.602707]}]}
```

Cheap enough (≈2.8 s for a 60 MP frame — the whole lossless JPEG still has to be
decoded to prove the file is usable) to use as a pre-flight check.

## Errors

```json
{"ok":false,"command":"merge",
 "error":{"code":"geometry_mismatch",
          "message":"frames are not mergeable: P4270052.dng differs from L1030664.dng"},
 "tool":{…}}
```

| `error.code` | exit | meaning / what the host should say |
|---|---|---|
| `not_tiff` | 3 | not a TIFF/DNG container at all |
| `not_a_cfa_dng` | 3 | no CFA plane — probably a JPEG/HEIC or an odd DNG |
| `linear_dng` | 3 | `PhotometricInterpretation=34892`; there is no mosaic to merge. This is what Lightroom's "Merge to HDR" and Apple ProRAW produce. |
| `unsupported_compression` | 3 | Deflate/JXL DNG — not implemented yet |
| `bad_geometry` | 3 | broken tile/strip table |
| `bad_lossless_jpeg` | 3 | corrupt entropy-coded data |
| `io_error` | 3 | missing/unreadable file, no permission |
| `geometry_mismatch` | 4 | frames differ in size, CFA pattern or CFA phase |
| `no_overlap` | 4 | aligned frames share no pixels |
| `no_frames` | 4 | empty input list |
| `write_failed` | 5 | cannot write the output path |
| `usage` / `unknown_command` | 2 | host bug |
| `internal` | 6 | report with the stderr log |

## Progress (optional)

```
{"event":"progress","phase":"decode","index":1,"total":3,"file":"/p/A.dng"}
{"event":"progress","phase":"merge","frames":3}
{"event":"progress","phase":"encode","bits":16}
{"event":"progress","phase":"done","bytes":121229748}
```

Phases in order: `decode` (once per frame, carries `index`/`total`) → `merge` →
`encode` → `done`. Not emitted by `inspect` (only `inspected`, per file).

## Sizing / cost

Measured on this machine (M-series, release build, 9536×6344 Leica SL3 DNGs):

| step | 1 frame | 3 frames |
|---|---|---|
| `inspect` | 2.6 s | 7.8 s |
| `merge` wall clock | — | **15 s** (decode 3×2.6 + align/merge ~4 + encode 3) |
| output size | — | 121 MB (16-bit, `--headroom 4`) |

The host should run this off the main actor, keep one child at a time
(the tool is single-threaded and memory-hungry: ~3 GB peak for three 60 MP
frames), and cap concurrency at 1–2.

## Versioning

`tool.protocol` only changes when the wire format changes. Adding a new
optional field or a new `error.code` is *not* a protocol bump; the host must
ignore unknown keys, which every JSON field here allows.
