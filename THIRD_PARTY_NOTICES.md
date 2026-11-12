# Third-party notices

Photons is MIT-licensed (see `LICENSE`). It links exactly **one** third-party package, and uses
one third-party model (not vendored, not linked) in the optional `PhotonsExtensions` denoise plugin.

## GRDB.swift

- Version: **7.11.1** (pinned in `Package.swift` / `Package.resolved`)
- Upstream: https://github.com/groue/GRDB.swift
- License: **MIT**
- Used by: `PhotonsCatalog` (the SQLite layer: connections, migrations, record mapping)
- Why: the catalog needs WAL, a migration ladder, and typed row decoding. Hand-rolling that is
  ~700–900 lines of the most error-prone code in the project (WAL, a migration ladder, typed row
  decoding, and soft-delete / offline bookkeeping that has to survive a `kill -9`).

Copyright notice as required by the MIT license:

```
Copyright (C) 2015-2026 Gwendal Roué

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

### Transitive dependencies

Verified at `swift package resolve` time on 2026-10-25: **1 pin** in `Package.resolved`
(`grdb.swift` only). GRDB bundles its own copy of the SQLite amalgamation.

## SQLite

SQLite is in the **public domain** (https://sqlite.org/copyright.html). GRDB compiles it in;
no separate license obligations apply.

## nonlocal-matchfilter (AI denoise model)

- Upstream: https://github.com/MIA-UIB/nonlocal-matchfilter (arXiv:2604.17453)
- License: **MIT** — Copyright (c) 2026 Marco Sánchez Beeckman
- Used by: `PhotonsExtensions` — the denoise *plugin* runs the released
  `rawnoise_25_15_9nbr` network weights (RAW-to-RAW: 8 input channels = 4 CFA sites + 4 noise-σ
  maps, 4 CFA channels out) and writes the result back as a DNG.
- What we ship vs. what we wrote:
  - **Not vendored.** The model runs in the Python/PyTorch reference implementation outside this
    repository; this target only consumes *samples* and writes the DNG. No line of their C++/CUDA
    or Python is copied into Photons.
  - The two operators the reference implementation ships as CUDA extensions are replaced with
    Metal-backed equivalents in our port: `deform_neighbourhood` → `F.grid_sample`
    (verified equivalent to 4.2 × 10⁻⁶ against a literal numpy transcription of their kernel), and
    `patch_match` is unused (only the `Cherel*` ablation models call it; the released weights are
    `SimpleBlockMatchingUNet`, deform only).
  - `RawLosslessJPEG` / `DNGRawWriter` / `SourceDNG` / `SourceDNGDecode` are our own
    implementation against the TIFF 6.0 / DNG 1.7 / JPEG (SOF3) specifications.
- Attribution is kept anyway: the network architecture and the released weights are theirs, and the
  MIT notice travels with them.

Copyright notice as required by the MIT license:

```
MIT License

Copyright (c) 2026 Marco Sánchez Beeckman

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

The same author's two helper packages are MIT as well: `deform-neighbourhood-sampling`
(Copyright (c) 2024) and `patchmatch` (Copyright (c) 2025) — neither is linked by Photons; the first
is replaced by `grid_sample` and the second is unused.

The **training data** and the **weights' own terms** are a separate question from the code licence.
Their README states the datasets are public; if this plugin is ever shipped commercially, confirm the
weights' terms with the authors before bundling them rather than shipping the download.

## Deliberately *not* linked

`LibRaw`, `Exiv2`, `libheif`, `x265`, `lensfun` — see `docs/architecture-decisions.md` §3 (D1)
and `local/research/licensing.md`. Decoding is `CIRAWFilter`, metadata is ImageIO
(`CGImageMetadata` for XMP), output is ImageIO, colour is ColorSync.

## Read but never copied

`euynus/PhotoCatalog` (GPL-3), `wmwallace/Kelvin` (AGPL-3), `888wing/latent` (BSL-1.1),
`pdcgomes/redlamp` (MPL-2.0), `AustinGoodnight/curves` (GPL-3) informed designs and pitfalls only;
no source was copied. The M2 schema shape (wide `assets` + cold 1:1 satellite table, import session
ledger, `content_hash`/`quick_hash` pair) was designed from those readings and is our own code.


## hdrmerge-swift (vendored GPLv3 executable, not linked)

- Upstream: <https://github.com/chemharuka/hdrmerge-swift> — **GPL-3.0-or-later**
- Vendored at `Vendor/hdrmerge-swift/` (verbatim, commit recorded in its `VERSION.txt`;
  the full GPL text is `Vendor/hdrmerge-swift/LICENSE`). Not a SwiftPM dependency of this
  package — `swift package describe` lists one dependency (GRDB) and no hdrmerge target.
- `scripts/build-hdrmerge.sh` compiles it and copies the executable into
  `Photons.app/Contents/Resources/bin/hdrmerge-swift`. Photons then **spawns it as a child
  process** and exchanges file paths and JSON on stdio; nothing from it is compiled into the
  Photons binary, and `PhotonsExtensions/HDR/HDRMergeClient.swift` contains only process/JSON
  plumbing, no merge algorithm.
- Why that is compatible with Photons being MIT: GPLv3 §5 (last paragraph) says including a
  covered work in an *aggregate* does not extend the licence to the other parts, and the GNU GPL
  FAQ (`#MereAggregation`) draws the line at "pipes, sockets and command-line arguments" versus
  "linked together in a shared address space". See `VENDOR-hdrmerge-swift.md` and
  `LICENSE-SCOPE.md`.
- Obligations discharged at bundle time (`scripts/bundle-hdrmerge.sh`): the GPL text and a §6(d)
  source offer are written into `Contents/Resources/licenses/`, and the binary's sha256 into
  `Contents/Resources/bin/`. Because the source is vendored in this same tree, the offer points at
  something the recipient already has.
- Only this executable and `Vendor/hdrmerge-swift/` are GPLv3. The Photons application remains MIT.
- The feature is optional at runtime: with no tool built, the 合并 HDR DNG… entry is unavailable and
  nothing else changes.
- hdrmerge-swift is itself a Swift port of HDRMerge (© 2012 Javier Celaya, GPLv3):
  <https://github.com/jcelaya/hdrmerge>

## ansel-denoise-swift (vendored GPLv3 executable, not linked)

Same arrangement as `hdrmerge-swift` above, for the same reason.

- Upstream: <https://github.com/aurelienpierreeng/ansel-denoise> — **GPL-3.0-or-later**
  (the training pipeline for Ansel's `rawdenoiseai` module). This is a Swift + Metal **rewrite**
  of that network, so it carries the same licence: the UNet definition
  (`src/ansel_denoise/model.py`), the five-plane input encoding and the σ-map convention
  (`src/ansel_denoise/noise.py`) are derived from upstream.
- Vendored at `Vendor/ansel-denoise-swift/` with the full GPL text in its `LICENSE` and the
  aggregation argument in its `LICENSE-SCOPE.md`. **Not** a SwiftPM dependency — this package
  still lists exactly one dependency (GRDB).
- Photons spawns `ansel-denoise-swift` as a child process and exchanges float32 mosaic buffers
  through temporary files, plus JSON on stdout. `PhotonsExtensions/Denoise/AnselDenoiseClient.swift`
  (MIT) contains process/JSON plumbing only; `AnselDenoiseService.swift` (MIT) owns the tiling,
  feathering and normalization, which are product logic and not derived from upstream.
- What it computes: a **denoised RGGB mosaic**. Pair it with `DNGRawWriter` to get a legal
  lossless DNG. Upstream uses the same design (mosaic in one full-resolution plane, CFA and noise
  level as input planes) so one weight set serves every profiled camera without retraining.
- Model weights (`.anselnn`) are **not** vendored. They are fetched from the upstream
  `models/manifest.json` and verified by sha256. Upstream licenses its training corpus
  (CC0 / per-shard CC / ATDL-1.1) in a way that permits training and commercial use of the
  resulting weights, but places no extra restriction on the weights themselves.
- Only the two vendored executables and their `Vendor/` trees are GPLv3. The Photons
  application remains MIT. The feature is optional at runtime: with no tool built, the
  denoise entry is unavailable and nothing else changes.
