# iPad Developer Beta 0.1.0 (4) — 2026-11-17

Tracking: **IPAD-09-RELEASE**. All iPad content changes, Simplified Chinese and lens-profile details ship together in [PR 3](https://github.com/chemharuka/photons/pull/3). Detailed feature commits and checks are in the [implementation report](ipad-content-update-2026-11-16.md). PR 2 remains the prerequisite and should merge first; no previous branch was deleted or rewritten.

## Published result

- App: Photons Studio Preview, `6835653664`, bundle `com.leoaokma.photons.ipad-preview`.
- Build: **0.1.0 (4)**, Apple build ID `dc8deaac-0a9f-4e9e-a3d9-9245f7e8d87e`.
- Xcode upload succeeded at **00:31:45 EST**; Apple processing completed, test notes were saved, and only the existing **Developer Beta** internal group was added.
- At **00:35 EST**, the group page showed build 4 **Testing**, **4 testers / 3 builds** (4, 2, 1). The group already had 4 testers before this action; none were added, removed or invited. The build is available to the group; this does not assert tester installation.
- Build 1 remained **Waiting for Review** externally. No Private Beta submission, tester-list or Mac distribution changes were made.
- Build 3 (`e83e048d-28ae-4807-b8b8-c1d207abc251`) uploaded at 00:17 EST from pre-update main, but was superseded before distribution and remains in no group.
- Verification used the authenticated **Codex built-in browser**. Local proof: `local/build-logs/ipad-content-update/developer-beta-build-4.png`.

[Developer Beta builds](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835653664/testflight/groups/bf208e19-5d77-4e4b-9a23-65e7a81ec2db/builds) · [Build 4 details](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835653664/testflight/ios/dc8deaac-0a9f-4e9e-a3d9-9245f7e8d87e)

## Source, package and verification

- Exact application source: `dfebb54e0db4c3de9630b9f34212afeada31fb96`; includes main `737f92d`, cache-generation fix `074d036`, histogram alignment `be73c42`, notices `dfebb54`. Later release documentation does not change app inputs.
- Archive: `.build/ipad-testflight/Photons-iPad-0.1.0-4.xcarchive`; uncompressed app **118,000,242 bytes / 112.5 MiB**.
- Executable SHA-256: `8c677f717b798f81760a177c8cc5a0276cd8b29b81f735882930f953505e8429`. Matching executable/dSYM UUID: `1D3F57BB-8B25-3704-B108-C0CC1B87DCFA`.
- Strict/deep code signature passed, App Store profile with `get-task-allow=false`, no provisioned-device list, iPad-only device family `[2]`, iPadOS 18+, en/zh-Hans resources verified against source. Opaque source icon is 1024×1024.
- App and GRDB privacy manifests, full notices/licenses, 43XL calibration and shared NLMF model are present. Model weight bytes/hash match main. No private RAWs are bundled. The upstream model adds 64,386,304 weight bytes; there is no iPad UI for its denoise workflow yet.
- Full main-integration test run: engine 19 passed / 1 explicit skip, UI 10/10 passed. Follow-up cache 2/2 and histogram/Chinese UI 4/4 passed. Distinct final coverage: **31 passed / 1 skipped / 0 failed**. Six-frame 100 MP RAW panorama ran and passed; the skipped test requires a different absent optional fixture.
- English/Chinese checks: all 348 referenced keys exist and placeholders agree; all upstream translations are preserved. Full-screen Chinese layouts were inspected on 13-inch and 11-inch iPad simulators.
- Local evidence: `09-main-full-suite.log`, `09-cache-generation.log`, `09-histogram-main.log`, `09-archive-4.log`, `09-archive-4-validation.json`, `09-upload-4.log` under `local/build-logs/ipad-content-update/`. Signing material, screenshots and local logs remain ignored.

## Limits and rollback

Physical-device HDR appearance, available memory, sustained thermals and power savings remain beta validation items. The cache budgets cover engine previews, not total app memory. RAW decoding can still require full-source memory. Language changes take effect after relaunch. Reverting this documentation does not withdraw a TestFlight build; any distribution rollback must explicitly select the affected build/group. Existing builds 1 and 2 remain available internally.

## Saved What to Test — English

iPad content update — 0.1.0 (4)

1. Panorama Close: stitch a preview, then close without exporting. The temporary composite should disappear and the previous photo/grid should return. A confirmed export should continue after dismissal.
2. Browsing: double-tap a grid photo to open it. Swipe left/right at Fit to move through the current folder/search results; the first/last photo should stop navigation. Tapping a selected grid photo to hide its inspector should clear its selection.
3. Detail zoom: choose 50%, 100%, 200% or a custom percentage at the upper right. Double-tap switches between Fit and that target. Pan after zooming and check that actual edited detail arrives. 100% maps image pixels to display pixels.
4. Library folders: create, rename and remove folders; move selections and import into a selected folder. One local library is used. Removing a folder keeps its photos and edits in Unfiled.
5. Histogram: check the fixed SDR/HDR axis and neutral RGB overlap, plus RGB distributions, HDR stops, display ceiling, output/sample dimensions and above-white/high/low clipping. Touch the histogram for bin readouts.
6. Cache: repeatedly switch HDR/SDR on the same photo and panorama. Check reuse after relaunch, invalidation after edits or engine upgrades, and detail rendering. Settings show cache disk size, file count and preview memory; clear it and confirm originals, edits, folders, profiles and exports remain.
7. Chinese: General > Language > 简体中文, then fully quit and reopen Photons. Browse, edit, stitch, export and inspect settings/profile details. Switching back to English also takes effect after relaunch.
8. Lens profiles: open a profile from Settings > Lens profiles. Inspect metadata, notes, per-orientation coverage and shift ranges, then expand calibration frames for sensor/pixel dimensions, capture information and measurement grids.
9. Regression: test LCC, panorama exposure/highlight controls, full-resolution and resized HDR/SDR/DNG exports, automatic library import and Files sharing.

Please report your iPad model, iPadOS version, source format/dimensions and exact steps for crashes, slow detail updates, memory pressure or incorrect HDR appearance. Large RAW decoding still depends on available device memory; processing currently requires the app to remain active. User filenames and profile notes are preserved in their original language.
