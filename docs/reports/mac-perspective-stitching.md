# macOS perspective stitching

Base: upstream/main `737f92d54056bf4f77fe93daa1c366e6bae639a1`. Branch: `codex/mac-perspective-stitching`. PR: https://github.com/chemharuka/photons/pull/4 (open, mergeable when checked on 2026-11-17).

The request is to audit the iPad perspective stitcher and expose the shared capability on macOS in a separate PR. HDR/LCC image-quality diagnosis is separate and makes no production rendering changes.

## Independent changes and dependencies

| ID | Acceptance goal | Dependencies |
| --- | --- | --- |
| MAC-PERSPECTIVE-01 | Preserve the capture mode across the export-worker snapshot; read legacy snapshots as shift. | None |
| MAC-PERSPECTIVE-02 | Reject projective transforms whose horizon crosses a source image before computing canvas bounds or rendering restored geometry. | None |
| MAC-PERSPECTIVE-03 | Enable Mac perspective selection, appropriate controls and failure handling; retain shift behavior. | 01, 02 |

## MAC-PERSPECTIVE-01 — export capture mode (`024c3ce`)

Previously the private worker snapshot preserved projective matrices but omitted `registrationMode`, so restoring a perspective plan silently changed it to shift. The snapshot now records the mode and defaults missing legacy values to shift, including old shift captures which used projective registration as a fallback.

Files: `PanoramaSnapshot.swift`, `PanoramaProvenanceTests.swift`. Validation: `swift test --filter PanoramaProvenanceTests` passed 4 tests, 0 failures on 2026-11-17. Limitations: old snapshots cannot recover an omitted capture mode; interpreting them as shift preserves the previous contract. This change is additive and can be reverted independently before the Mac entry point is enabled.


## MAC-PERSPECTIVE-02 — finite image domains (`fc60f73`)

An invertible homography can have finite corners while a projective horizon crosses its interior. Four individually plausible transforms reproduce this after composition. Check the affine denominator at all four corners for a consistent sign and a relative distance from zero before computing the canvas. Apply the same validation to direct preview/export plans, worker snapshots and portable manifests.

Files: `PanoramaTransform.swift`, `PanoramaEngine.swift`, `PanoramaSnapshot.swift`, `PanoramaManifest.swift`, two panorama test suites, English/Chinese messages. Validation: `swift test --filter 'ProjectiveRegistrationTests|PanoramaProvenanceTests'` passed 8 tests, 0 failures. Includes composed-horizon rejection, invertible negative matrix scale, on-edge horizons, invalid restored/direct plans, robust fitting with outliers, unrelated/collinear matches and metadata round trips. Limits: this validates the geometric domain, not scene parallax or aesthetic registration quality. No solver thresholds, HDR/LCC pixel operations or shift behavior changed. No dependencies; the Mac entry point depends on this guard.


## MAC-PERSPECTIVE-03 — macOS entry point (`8bf99a9`)

The mode chooser now starts the same `PanoramaEngine.analyze(registrationMode: .perspective)` used by iPad. The workspace identifies the selected mode and offers retry/change-mode actions. Perspective registration ignores saved shift readings and sensor overrides; its inspector exposes seam controls and explains the planar-projection limits. It hides body travel, physical shift coordinates and panorama LCC. Export does not attach a selected shift body, lens profile or invented millimetre offsets. Registration failure clears the previous plan and reports the error rather than creating a shift-alignment draft. Shift mode retains its existing manual draft fallback. English and Simplified Chinese UI strings are included.

Files: `Sources/PhotonsUI/PanoramaWindowController.swift`, localization resources, `Tests/PhotonsUITests/PanoramaPerspectiveTests.swift`. Depends on 01 (`024c3ce`) and 02 (`fc60f73`). The model is internal so the Mac workflow can be exercised directly; no public API is added. It reuses the solver already on upstream/main, not a second implementation. The deterministic texture fixture and perspective perturbation follow `MobileSamples.create` / `IPadEngineTests.testPerspectiveModeFitsWarpAndPreservesCaptureModel` from iPad source `dfebb54e0db4c3de9630b9f34212afeada31fb96` (PR #3); no private photos are included.

Validation on 2026-11-17:

- `swift test --filter PanoramaPerspectiveTests`: 2 passed, 0 failures. Exercises the actual Mac model with generated overlapping TIFFs, verifies a non-translation warp, ignores unrelated physical readings, exports/re-reads DNG metadata through a worker snapshot, prevents perspective LCC, returns to the chooser, rejects featureless input without a stale plan, and retains the shift draft fallback.
- `swift test --filter 'PhotonsPanoramaTests|PanoramaPerspectiveTests|PanoramaHDRTests'`: 69 discovered, **63 passed, 6 skipped, 0 failures**. The six skips require optional external Boston/RAW/export fixtures; the private cloud diagnosis is a separate run, not counted as those tests passing. Existing panorama HDR preview tests passed. Full package compilation completed.
- `git diff --check`: clean.

Limits: this is a planar homography stitcher for modest rotation/tilt and distant or approximately flat subjects. Existing checks include robust fitting, inlier coverage, graph connectivity, cycle consistency and canvas limits. It has no global bundle adjustment, cylindrical/spherical projection or depth-dependent parallax correction. A successful fit still needs visual inspection. This turn does not claim a physical iPad retest or a new TestFlight release. HDR mapping and LCC recovery code remain unchanged. Revert 03 first if withdrawing the Mac entry point; 01 and 02 remain useful independent correctness fixes.

## Review / integration

This branch is based directly on upstream/main and does not include the unmerged content of PR #2 or #3. Both platforms already share the geometry engine on main. PR #2 also edits `PanoramaWindowController.swift` for brightness controls; preserve those controls when integrating both branches. The change here does not implement or replace tone mapping. All changes retain independent commit history.


## Delivery record

| Tracking ID | Commit | Dependencies |
| --- | --- | --- |
| MAC-PERSPECTIVE-01 | `024c3ce` | None |
| MAC-PERSPECTIVE-02 | `fc60f73` | None |
| MAC-PERSPECTIVE-03 | `8bf99a9` | 01, 02 |
| MAC-PERSPECTIVE-DOC | This documentation-only delivery commit | 01–03 |

All three implementation commits were pushed to `origin/codex/mac-perspective-stitching` before opening PR #4. The local full package build and tests above are the validation evidence; GitHub reports no configured status checks on this PR. No branches or user workspaces were removed. The HDR/LCC cloud investigation and private evidence remain outside this public PR.
