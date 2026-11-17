# iPadOS development preview

This is an experimental, independently buildable iPad app. Its purpose is to exercise the existing Photons editing, LCC and panorama engines on iPadOS. It is not yet a feature-complete desktop replacement. Private beta distribution uses the separate **Photons Studio Preview** App Store Connect record; see [iPad TestFlight](ipad-testflight.md) for signing, upload and current status.

See [Mac / iPad development suggestions](mac-ipad-development.md) for the **advisory**, revisable development approach.

## Build and run

- Xcode with an iOS 18+ SDK and an installed iPad simulator runtime; deployment target: iPadOS 18.
- Open `Apps/iPad/PhotonsIPad.xcodeproj`, select **Photons iPad Preview**, choose an iPad, and Run.
- For development on a physical iPad, select your development team in Signing & Capabilities. The preview uses a separate bundle identifier, `com.leoaokma.photons.ipad-preview`, and does not replace the Mac/TestFlight app. Invited TestFlight testers do not need Xcode or a development provisioning profile.
- Command-line builds and tests: `python3 scripts/ipad-preview.py build` / `python3 scripts/ipad-preview.py test` / `python3 scripts/ipad-preview.py run`.
- `make app` remains the Mac build. It does not package or publish an iPad app.

The preview starts in English and supports Simplified Chinese. Choose **General → Language → 简体中文** and restart the app; language stays consistent throughout a running session, as on Mac. System panels follow iPadOS settings, while filenames and user profile notes remain unchanged. The existing app icon is included in the iPad asset catalog.

## Current implementation

| Area | Preview coverage |
|---|---|
| Library | One persistent library, organizational folders with create/rename/remove/move, Files/folder import as managed copies, duplicate control, search, ratings |
| Grid | Aspect-fit thumbnails, pinch sizing, tap to toggle inspector and selection together, double-tap to open, long-press multiselection |
| Layout | Hideable library sidebar, top workspace toolbar, right inspector, grid/single icons, no filmstrip, full-screen settings tabs (General / Photo library / Lens profiles), settings button / Control-comma |
| Editing | Shared Metal graph; exposure, tone, white balance, HSL, grading, calibration, detail/effects, numeric crop, rotation and flip |
| History | Shared snapshot model, undo/redo, history navigation, imported-state reset, configurable history length |
| Preview | Swipe navigation at Fit; double-tap Fit ↔ 50/100/200/custom %, visible-region detail rendering, paired HDR/SDR caches, detailed histogram, cache size/cleanup settings |
| Panorama | Large preview workspace, existing registration/seam engine, four body-orientation diagrams, draggable sensor rectangles in body travel limits, optional measured shift guidance, cancellable foreground tasks |
| LCC | Strict matching flat, lens-profile single-image correction, panorama profile correction with optional coverage crop, recorded-manifest post-export correction |
| Profiles | Bundled sample, import/share/create, full metadata and per-orientation coverage, expandable capture and measurement-grid details |
| Output | Separate HDR/SDR choices, JPEG/HEIC/TIFF/PNG and 16-bit lossless linear DNG, embedded panorama geometry, output auto-import and system Save/Share |

Exports offer **Full resolution** and 2048 / 4096 / 6000 px long edge, without upscaling. Before rendering, the app estimates source/output memory against the current process budget and asks for a smaller size if it cannot fit; it never silently reduces the requested size. Linear DNG uses lossless tiled compression. Output goes to Documents/Exports; Save/Share can copy it elsewhere. Large original-resolution Boston exports still need physical-iPad memory validation.

Folders classify photos inside the single library; a photo belongs to at most one folder. **All photographs** and **Unfiled** provide global/unassigned views. Removing a folder keeps its photos and edits. Import into the selected folder or use **Move to folder** on a selection. Another `.photonslibrary` cannot be imported as a second library.

Original photos are copied into `Documents/iPad Preview.photonslibrary`; the Mac library is not opened or changed. Profile files live in the iPad app container and remain user-readable/exportable. No subscription, invite-code service, photo upload or cloud synchronization is added.

Panorama opens full-screen and first requires **Shift panorama** or **Perspective panorama**. Shift starts with translation matching and retains the existing small-perspective fallback; Perspective estimates projective transforms for every candidate pair instead of accepting a translation-only graph. Alignment starts only after a mode is selected. Dragging uses a fixed canvas coordinate space and moves each frame's geometric center by the finger delta. It commits approximate millimetre positions on release, marks the preview as stale and disables export until **Update alignment** succeeds. **Revert** beside Layout restores the last successful layout immediately, without decoding or matching again; pending alignment-option changes still require an update. In Shift mode, camera body rotation changes the allowed travel; selecting a source row brings its overlapping rectangle to the front. The shared engine still verifies overlap rather than blindly accepting the drawing. HDR/SDR, LCC profile correction and export remain inside this workspace. Starting export closes it and returns progress to the main toolbar. **Close** without export discards the temporary composite and restores the original photo/grid; cancelled work cannot refill the discarded preview. A confirmed export continues after the workspace closes.

Panorama brightness controls sit below the preview on both iPad and this fork's Mac app. **Exposure (EV)** adjusts the whole image (−4…+4). **HDR highlight brightness (stops)** sets a hue-preserving highlight shoulder's upper limit (0…4 stops above SDR white, or 1×…16×); it is not the screen backlight. The default is exposure 0 and 2 highlight stops (4×). Lower the highlight limit and increase exposure to lift a dark foreground while retaining bright detail. Reset returns those defaults. The shared LCC highlight protection no longer reduces the whole image's exposure from a bright percentile. Adjustments reuse cached source previews and existing registration/seams; they do not repeat RAW decoding or position solving. Preview/histogram and all panorama output formats use the same chosen adjustments, which are frozen into Mac worker snapshots and recorded as already-applied provenance in exports. Linear DNG remains losslessly encoded, but choosing a highlight shoulder is a deliberate tonal edit; it is not an unmodified sensor-data export. Legacy snapshots without tone settings remain neutral. Apply LCC before these rendered tonal adjustments for the most faithful correction.

In the large view, left/right swipes at Fit follow the current folder/search order and stop at the ends. After zooming, dragging pans the image. The upper-right zoom control chooses the double-tap target (50%, 100%, 200%, or custom 10–800%); double-tap always returns between Fit and that target. 100% means one source pixel per physical display pixel. Zoom/pan requests actual edited viewport pixels with a processing halo. RAW decoding may still need the entire source; insufficient memory leaves the base preview visible and explains the limit.

The inspector histogram includes RGB distributions, code/HDR-stop axes, display ceiling, above-white/high/low clipping statistics, output/sample size and touch bin readouts. The SDR/HDR axis stays half-and-half in both modes. Bounded sRGB additive bands preserve neutral overlap, and pixel-interval coverage retains narrow peaks, matching current Mac semantics; touch counts are not a pixel-under-finger photo color sampler.

HDR/SDR previews use tagged half-float images and a Core Animation surface that explicitly selects dynamic range. A scene-linear render produces paired HDR/SDR display images and histograms. Unchanged photos reuse them when switching modes, including after restart. Separate engine memory budgets cover photos (96 MiB), thumbnails (16 MiB), and viewport details (48 MiB); persistent paired previews use up to 512 MiB and evict oldest entries. These limits exclude current UI images and decoder/GPU allocations. Edit/source changes and shared decoder/render algorithm generations invalidate the cache. Settings show disk size, file count and engine preview memory, and can clear disposable caches while preserving originals, edits, folders, profiles and exports. An SDR-only display shows a limitation notice; HDR brightness must be assessed on a capable physical device. Temperature controls and explicit decoder requests share **800–14000 K** on Mac and iPad; as-shot remains available.

Perspective uses a planar projection and is an early implementation for modest camera rotation, not a spherical/360° stitcher. Its capture mode is embedded in exports. Apply LCC to individual inputs before perspective stitching: the shared post-LCC engine rejects the shift-based physical-position model for these exports instead of treating a rotated camera as a shifted sensor. Legacy manifests without a mode retain their previous behaviour.

The four body-orientation buttons use the same travel-outline and shift-zero diagrams as the Mac. Under panorama LCC, **Crop to corrected area** uses the shared Mac coverage calculation to keep the largest rectangle fully covered by the calibration. It defaults off. After applying the lens profile, changing this checkbox refreshes the preview and output dimensions using the existing correction, without decoding the RAWs or solving their LCC positions again. Turning it off restores the full panorama; the exported metadata records the crop when enabled.

## Local Boston sample build

The 43XL/CFV 100C developer-created lens profile ships through the shared `PhotonsPanorama` resources. To include the owner's four original test photographs in a local preview, place `B0000659.3FR` through `B0000662.3FR` in `local/ipad-samples/` (or set the `PHOTONS_IPAD_SAMPLE_DIR` build setting). The app build phase copies just those four files into `BostonSamples`; the library sidebar then offers **Load Boston test photos**. `python3 scripts/ipad-preview.py run --release --boston` builds an optimized local preview with the samples and imports them on launch. Debug processing of 100 MP RAW files is substantially slower. Importing makes managed library copies and obeys the duplicate-import setting.

The full RAWs total approximately 810 MB. They are excluded from Git; a fresh checkout has generated diagnostic examples instead. Debug builds include available local samples; Release builds omit them by default. Set `PHOTONS_INCLUDE_BOSTON_SAMPLES=NO` or `YES` with `xcodebuild` to choose explicitly. Bundling these local test photos is separate from publishing them to the source repository. There is no download or photo-upload service.

On recent Xcode installations the simulator interface may be named **Device Hub**. The helper supports both the traditional Simulator path and Device Hub. If a booted simulator is not frontmost, select the iPad in Device Hub's Window menu.

## Remaining work

The intent is to bring the complete workflow over incrementally. The following are **not implemented in this preview UI**: touch curve/mask/heal editors, complete preset/library-management interfaces, social-media slicing, advanced batch export/destination/watermark controls, and the macOS external AI denoise / exposure-stack HDR helpers. Their shared data/processing code being present does not make their interfaces available.

Full-resolution large panoramas, robust resumable background execution, device-specific HDR display headroom and sustained memory/thermal behaviour still need physical-iPad validation. Jobs currently run in-process while the app is active; macOS subprocess crash isolation does not carry over. Cooperative cancellation cannot interrupt every system RAW decode/encode in the middle of a call.

Rendered HEIC/TIFF post-LCC is an approximation based on embedded geometry and rendered-RGB calibration. The inspector recommends correcting original sources before stitching when exact reconstruction is needed.

## Validation

Integration tests exercise real shared engine operations using generated overlap/calibration fixtures; UI tests cover the iPad interaction contract. Generated fixtures contain no user photographs. See the [content-update record](reports/ipad-content-update-2026-11-16.md) for the individual changes and latest tests, and the [original validation record](reports/ipad-preview-validation.md) for commands, actual Boston RAW coverage, UI checks and limits. Simulator verification is not a claim about physical-iPad camera support, HDR fidelity, energy use or App Store approval.
