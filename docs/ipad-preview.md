# iPadOS development preview

This is an experimental, independently buildable iPad app. Its purpose is to exercise the existing Photons editing, LCC and panorama engines on iPadOS. It is not yet a feature-complete desktop replacement. Private beta distribution uses the separate **Photons Studio Preview** App Store Connect record; see [iPad TestFlight](ipad-testflight.md) for signing, upload and current status.

See [Mac / iPad development suggestions](mac-ipad-development.md) for the **advisory**, revisable development approach.

## Build and run

- Xcode with an iOS 18+ SDK and an installed iPad simulator runtime; deployment target: iPadOS 18.
- Open `Apps/iPad/PhotonsIPad.xcodeproj`, select **Photons iPad Preview**, choose an iPad, and Run.
- For development on a physical iPad, select your development team in Signing & Capabilities. The preview uses a separate bundle identifier, `com.leoaokma.photons.ipad-preview`, and does not replace the Mac/TestFlight app. Invited TestFlight testers do not need Xcode or a development provisioning profile.
- Command-line builds and tests: `python3 scripts/ipad-preview.py build` / `python3 scripts/ipad-preview.py test` / `python3 scripts/ipad-preview.py run`.
- `make app` remains the Mac build. It does not package or publish an iPad app.

The preview starts in English. Shared parameter labels use Photons localization; complete Chinese mobile UI is a later stage. The existing app icon is included in the iPad asset catalog.

## Current implementation

| Area | Preview coverage |
|---|---|
| Library | Files/folder import as managed copies, persistent shared catalog, content deduplication toggle, search, ratings |
| Grid | Aspect-fit thumbnails, pinch sizing, tap to toggle inspector, long-press multiselection |
| Layout | Hideable library sidebar, top workspace toolbar, right inspector, grid/single icons, no filmstrip, full-screen settings tabs (General / Photo library / Lens profiles), settings button / Control-comma |
| Editing | Shared Metal graph; exposure, tone, white balance, HSL, grading, calibration, detail/effects, numeric crop, rotation and flip |
| History | Shared snapshot model, undo/redo, history navigation, imported-state reset, configurable history length |
| Preview | HDR/SDR mapping, zoom/pan, cached thumbnails and histograms, progress during import/preview preparation |
| Panorama | Large preview workspace, existing registration/seam engine, four body-orientation diagrams, draggable sensor rectangles in body travel limits, optional measured shift guidance, cancellable foreground tasks |
| LCC | Strict matching flat, lens-profile single-image correction, panorama profile correction with optional coverage crop, recorded-manifest post-export correction |
| Profiles | Bundled developer sample, profile import/share, creation from selected calibration frames and confirmed positions |
| Output | Separate HDR/SDR choices, JPEG/HEIC/TIFF/PNG and 16-bit lossless linear DNG, embedded panorama geometry, output auto-import and system Save/Share |

Exports offer **Full resolution** and 2048 / 4096 / 6000 px long edge, without upscaling. Before rendering, the app estimates source/output memory against the current process budget and asks for a smaller size if it cannot fit; it never silently reduces the requested size. Linear DNG uses lossless tiled compression. Output goes to Documents/Exports; Save/Share can copy it elsewhere. Large original-resolution Boston exports still need physical-iPad memory validation.

Original photos are copied into `Documents/iPad Preview.photonslibrary`; the Mac library is not opened or changed. Profile files live in the iPad app container and remain user-readable/exportable. No subscription, invite-code service, photo upload or cloud synchronization is added.

Panorama opens full-screen and first requires **Shift panorama** or **Perspective panorama**. Shift starts with translation matching and retains the existing small-perspective fallback; Perspective estimates projective transforms for every candidate pair instead of accepting a translation-only graph. Alignment starts only after a mode is selected. Dragging uses a fixed canvas coordinate space and moves each frame's geometric center by the finger delta. It commits approximate millimetre positions on release, marks the preview as stale and disables export until **Update alignment** succeeds. **Revert** beside Layout restores the last successful layout immediately, without decoding or matching again; pending alignment-option changes still require an update. In Shift mode, camera body rotation changes the allowed travel; selecting a source row brings its overlapping rectangle to the front. The shared engine still verifies overlap rather than blindly accepting the drawing. HDR/SDR, LCC profile correction and export remain inside this workspace. Starting export closes it and returns progress to the main toolbar.

HDR/SDR previews use tagged half-float images and a Core Animation surface that explicitly selects dynamic range. HDR thumbnail caches retain the floating-point samples and histogram losslessly across launches. An SDR-only display shows a limitation notice; HDR brightness must be assessed on a capable physical device. Temperature controls and explicit decoder requests share **800–14000 K** on Mac and iPad; as-shot remains available.

Perspective uses a planar projection and is an early implementation for modest camera rotation, not a spherical/360° stitcher. Its capture mode is embedded in exports. Apply LCC to individual inputs before perspective stitching: the shared post-LCC engine rejects the shift-based physical-position model for these exports instead of treating a rotated camera as a shifted sensor. Legacy manifests without a mode retain their previous behaviour.

The four body-orientation buttons use the same travel-outline and shift-zero diagrams as the Mac. Under panorama LCC, **Crop to corrected area** uses the shared Mac coverage calculation to keep the largest rectangle fully covered by the calibration. It defaults off. After applying the lens profile, changing this checkbox refreshes the preview and output dimensions using the existing correction, without decoding the RAWs or solving their LCC positions again. Turning it off restores the full panorama; the exported metadata records the crop when enabled.

## Local Boston sample build

The 43XL/CFV 100C developer-created lens profile ships through the shared `PhotonsPanorama` resources. To include the owner's four original test photographs in a local preview, place `B0000659.3FR` through `B0000662.3FR` in `local/ipad-samples/` (or set the `PHOTONS_IPAD_SAMPLE_DIR` build setting). The app build phase copies just those four files into `BostonSamples`; the library sidebar then offers **Load Boston test photos**. `python3 scripts/ipad-preview.py run --release --boston` builds an optimized local preview with the samples and imports them on launch. Debug processing of 100 MP RAW files is substantially slower. Importing makes managed library copies and obeys the duplicate-import setting.

The full RAWs total approximately 810 MB. They are excluded from Git; a fresh checkout has generated diagnostic examples instead. Debug builds include available local samples; Release builds omit them by default. Set `PHOTONS_INCLUDE_BOSTON_SAMPLES=NO` or `YES` with `xcodebuild` to choose explicitly. Bundling these local test photos is separate from publishing them to the source repository. There is no download or photo-upload service.

On recent Xcode installations the simulator interface may be named **Device Hub**. The helper supports both the traditional Simulator path and Device Hub. If a booted simulator is not frontmost, select the iPad in Device Hub's Window menu.

## Remaining work

The intent is to bring the complete workflow over incrementally. The following are **not implemented in this preview UI**: touch curve/mask/heal editors, complete preset/library-management interfaces, social-media slicing, advanced batch export/destination/watermark controls, complete Chinese localization, and the macOS external AI denoise / exposure-stack HDR helpers. Their shared data/processing code being present does not make their interfaces available.

Full-resolution large panoramas, robust resumable background execution, device-specific HDR display headroom and sustained memory/thermal behaviour still need physical-iPad validation. Jobs currently run in-process while the app is active; macOS subprocess crash isolation does not carry over. Cooperative cancellation cannot interrupt every system RAW decode/encode in the middle of a call.

Rendered HEIC/TIFF post-LCC is an approximation based on embedded geometry and rendered-RGB calibration. The inspector recommends correcting original sources before stitching when exact reconstruction is needed.

## Validation

Integration tests exercise real shared engine operations using generated overlap/calibration fixtures; UI tests cover the iPad interaction contract. Generated fixtures contain no user photographs. See the [validation record](reports/ipad-preview-validation.md) for commands, actual Boston RAW coverage, UI checks and limits. Simulator verification is not a claim about physical-iPad camera support, HDR fidelity, energy use or App Store approval.
