# Post-stitch LCC and history preferences

## Changes

The lens-profile workspace now uses a large HDR/SDR preview with the same histogram and shared camera-placement diagram as the panorama workspace. Its sidebar lists source filenames and relative/absolute positions, highlights the selected reference frame, restores a recorded profile when available, and permits a manual reference override. Correction is previewed in this workspace before export; completed exports retain the existing background-job and auto-import flow.

The previous post-stitch UI rejected an image without `profileOffsetMM` before attempting any solve. It now prioritizes recorded optical origins or per-frame shifts, then estimates the origin using the saved source geometry, blend masks and rendered-RGB lens measurements. The scene/profile search is shared with the panorama solver. Source RAW files are not required. Crop, resize and projective transforms are inverted to find the correct sampling positions. Measured profile coverage constrains candidate origins; empty warped canvas corners are excluded from coverage failures. Recorded camera-body information is now retained even when the panorama is exported without LCC. Older manifests remain readable.

Scene-derived results are explicitly labeled as estimates and can be adjusted using any source frame as the reference. Relative placement alone does not identify an absolute optical origin. Rendered-RGB post-correction remains an approximation; it cannot recover the original camera samples, and camera-space correction before blending remains preferable.

General settings now offer history limits of 10, 20, 50 or 100 records, defaulting to 20. This limits the visible/undoable in-memory window; existing database history archives are preserved. Changing the limit does not change the current photo, including after undoing into the middle of a timeline. The History panel's Restore Import State command restores every develop parameter as one undoable action. The original import snapshot is read independently of the visible history window; originals and catalog ratings are unaffected.

## Verification

The latest results across the focused run and corrective reruns are **47 passing tests**. A separate `swift build -c release` also succeeds. They cover:

- Offline automatic position recovery from a synthetic rendered panorama with known calibration, recorded-shift reuse and crop/rotation coordinate inversion.
- Actual uncorrected DNG exports from Boston 641–643 and 644–646: automatic position estimation and post-stitch correction complete without a manual seed. These checks exercise the reduced-size exports from the previous validation, without reading source RAWs. They establish successful processing and metadata preservation, not measured ground-truth accuracy of the inferred shift.
- Resolution-independent post-correction, rejection of repeated correction, camera/profile orientation compatibility, projective manifest/snapshot round trips and export geometry.
- All four preference choices, invalid-value fallback, persistence, history-window reduction, reopening a catalog, restoring an evicted import state, undo/redo of restoration and changing limits while the current state is in the middle of history.
- Existing core history behavior and localized History-panel controls. An outdated literal-Chinese source assertion was updated to the existing localized Undo label.

The external-file test is opt-in via `PHOTONS_LCC_POST_DIR`, containing `B0000641_pano.dng` and `B0000644_pano.dng` with Photons stitch metadata. Private photos and generated exports are not committed.

No app bundle was replaced or relaunched. The installed local sandbox developer build remains `f2bb09a`, as requested. These targeted checks do not supersede the unresolved full acceptance failures in [fork-integration-validation.md](fork-integration-validation.md).
