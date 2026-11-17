# PANO-DEGHOST-01 — explicit deghost checkbox on Mac and iPad

Branch: `codex/panorama-deghost-control`, based directly on upstream/main `737f92d`. This PR intentionally contains one implementation commit and is independent of PR #2, #3, #4 and the subsequent UI/performance fixes.

The existing `avoidMotion` option already controls transient-object consensus and hard seam protection. Expose it as an explicit **Deghost / 防伪影** checkbox on both platforms, keep its existing enabled default, and explain that users can disable it when cloud/highlight boundaries appear. Replace the old label/control rather than adding two switches for the same option. The iPad checkbox is outside the collapsed alignment options.

On a clean registered iPad plan the checkbox now rebuilds seams from the frozen previews immediately. It retains registration, LCC and crop and updates the preview and export manifest together. Dirty physical/alignment settings still require Update alignment; that protects unapplied position edits. Mac uses its existing preview-refresh path. The option remains serialized in snapshots/manifests. HDR mapping and the seam algorithm are unchanged.

Scope: Mac/iPad panorama views, iPad engine/model seam refresh, English/Chinese strings, panorama and iPad tests. No dependencies on earlier feature PRs. Validation on 2026-11-17:

- `swift test --skip-update --filter PanoramaTests.testConsensusAvoidsTransientObjectAndMasksStayNormalized`: 1 passed. The controlled transient-object scene selects different source ownership with deghost off/on while retaining LCC offset/crop and geometry; snapshot/manifest retain the option.
- iPad Simulator `xcodebuild test -only-testing:PhotonsIPadTests/IPadEngineTests/testDeghostToggleReusesRegisteredGeometry`: 1 passed on iPad Pro 13-inch (M5), iOS 27.2. Preview generation and geometry preservation through off/on are checked; the iPad app and Mac package compiled.
- `git diff --check`: clean. Initial SwiftPM dependency submodule fetch stalled; reused existing pinned dependency checkouts and reran successfully.

Limitations: deghost is not a repair for clipped RAW channels; changing it can alter source choice elsewhere. No physical-device/TestFlight update in this change. Revert this single commit to restore the old controls and remove the iPad refresh API. Source: existing upstream implementation, no imported third-party code. See the commit body for the complete tracking information.
