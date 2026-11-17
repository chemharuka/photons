# Grid, import, DNG and panorama validation

Validated on the local Apple Silicon Mac on 2026-11-16 UTC, starting from `ebecce5`.

## Behavior

- The grid reads per-library persistent HDR/SDR histogram counts. Normal preview rendering records counts from a 256-pixel sample; older cached previews are backfilled incrementally without decoding originals. Selection reuses counts, while edits and the highlight ceiling invalidate the relevant recipe. Background backfill pauses under low-power/thermal pressure and during editing.
- Grid thumbnails fit the complete image and preserve portrait/landscape proportions. A persisted size slider changes column count without requesting a new RAW decode for each slider event. Asset and source-folder context menus support Reveal in Finder.
- Import defaults to skipping duplicates. Turning the option off creates independent asset IDs with separate edits, history and ratings, sharing the original bytes. Schema 7 removes uniqueness constraints on content/path while retaining foreign keys, indexes and triggers. The existing pre-migration database backup remains in use.
- Initial preview preparation runs one background request at a time and reports progress/cancellation in the main toolbar queue.
- Translation matching remains the first panorama path. Disconnected registrations can use a feature-consensus projective fallback, verified against finer image patches and geometric coverage. Rendering, seams, worker snapshots and post-stitch LCC retain the resulting transforms. Projective snapshots/manifests are version 2; translation records remain version 1.
- Stitch metadata uses bounded DEFLATE compression inside XMP, with backward reading of base64 JSON. Real uncompressed seam records were present in DNG tag 700 but were not returned by ImageIO; compression makes these records readable and reduces the tested XMP from about 4.1 MB to 42 KB.

## Actual Boston files

Automatic analysis and preview rendering passed for these source groups:

| Sources | Canvas pixels | Purpose |
| --- | --- | --- |
| 628–633 | 21,330 × 20,255 | Existing successful six-frame group |
| 641–643 | 11,799 × 20,322 | Previously failed vertical strip |
| 644–646 | 11,708 × 20,282 | Previously failed vertical strip |
| 653–658 | 18,393 × 18,266 | User-confirmed successful six-frame group |
| 659–662 | 21,305 × 15,366 | Existing four-frame regression group |

The user corrected the original nine-frame report: 653–658 stitch normally; 650–652 may have a different camera direction. The mixed 650–658 set is not treated as an acceptance defect.

The independent release worker exported 641–643 and 644–646 as tiled lossless JPEG DNG, with a 4,000-pixel long edge. Both reopened through CIRAWFilter at the expected dimensions, retained all three source transforms in a readable version-2 manifest, and had embedded previews. These checks validate worker/metadata integration at reduced output size; they are not full-resolution seam-quality measurements.

Two problematic large files were Capture One exports with uncompressed RGB16 strips, not Photons exports. Apple's RAW decoder returned an invalid small red image for them. Repacking the exact UInt16 samples as lossless JPEG tiles restored decoding:

| Original | Original bytes | Compatibility-cache bytes |
| --- | ---: | ---: |
| B0000662_Panorama.dng | 1,971,257,668 | 1,154,406,249 |
| B0000635_Panorama.dng | 1,119,415,452 | 596,738,006 |

The original files, timestamps and catalog identity stay unchanged. A disposable cache is reused on later opens. This is lossless container conversion, with no resize, tone mapping or quantization. Synthetic partial-tile tests compare decoded pixels before/after conversion; actual-file checks verify dimensions and plausible finite channel values. Photons' own linear DNG writer already uses lossless JPEG tiles; its shared encoder now compresses smooth/padded regions more efficiently.

## Automated coverage

The latest results across the focused workflow run and corrective reruns are **55 passing tests, no remaining failures in that selection**. Coverage includes histogram persistence/invalidation, 20 repeated selections with zero RAW decodes or new histogram computations, aspect-fit thumbnail sizing, import options, independent copies and schema migration, existing stack behavior, lossless JPEG round trips, DNG compatibility, projective fitting/outlier rejection, all five real Boston groups, portable crop/resize metadata, and the two real worker exports.

Opt-in fixture variables are `PHOTONS_BOSTON_DIR` for analysis/DNG checks and `PHOTONS_BOSTON_CORRECTED_EXPORT` for the worker export check. Images and generated exports are private local fixtures and are not committed.

This does **not** supersede the unresolved full acceptance failures documented in [fork-integration-validation.md](fork-integration-validation.md). The complete test suite has not become green through these targeted changes.

## Packaged runtime

The release sandbox package at `f2bb09a` passed strict code-signature verification and `--sandbox-check`: app sandbox enabled, security-scoped bookmark round trip, Apple M5 Pro GPU, denoise/HDR helper protocols, worker HDR HEIC export, metadata round trip and automatic catalog import.

The user's existing Panorama-Demo library migrated from schema 6 to 7 with all 122 assets retained, zero foreign-key violations and a `backups/library.bak-v6.db` backup. The running window visibly shows complete portrait/landscape thumbnails, the size slider, a populated grid histogram and a correctly decoded B0000662_Panorama.dng. The Mac was locked during the final GUI check, so interactive slider dragging, context-menu activation and import-panel clicking were not rechecked in this packaged build. Import controls and grid sizing have automated coverage above; Finder menu wiring was reviewed in code.

## Limits

A fitted rotation is an effective image transform, not a measurement proving physical vibration. Moving the lens can change viewpoint and produce depth-dependent parallax. A single projective transform, seam selection and blending improve these examples but cannot guarantee perfect alignment at every depth, around moving subjects or in arbitrary captures. RAW-before-stitch LCC remains preferable to correction of an already blended RGB panorama.

TestFlight distribution remains paused at the user's request.
