# Fork integration validation — 2026-11-16

The fork integrates upstream `23607f5`, including additive RGB histograms, guide-line solving and tolerance changes, crop-overlay occlusion, and the dehaze darkening cap. Conflict resolution retains the fork's neutral studio header, HDR/SDR axis behavior, localization, and background task button.

## Acceptance status

The release build succeeds. **Full acceptance is not green.** `make verify` was run with a local Boston RAW fixture; its UI test phase was stopped after recording 95 assertion failures across 24 test classes. Later acceptance stages were therefore not reached. This is a failed/partial acceptance run, not a complete passing run.

Failures include:

- Source-text and label assumptions changed by localization (for example the literal `AUTO BLACK` check), and the old matte-color scan matching a DNG parser's `0x0F` bit mask.
- UI expectations for curve regions, export-row sizing/truncation, and fixed toolbar locations.
- Pixel comparisons for chromatic aberration, crop transforms, zoom, and full-resolution rendering.
- A released-drag latency measurement above the test's 33.3 ms ceiling.

The fixed toolbar probe that now lands on the task button was corrected: controls remain explicitly hit-tested, and at least two actual blank title-bar probes must reach AppKit. The other acceptance failures remain unresolved; they have not all been reproduced on an unmodified upstream checkout and must not be described collectively as upstream defects or harmless test drift.

## Focused integration coverage

The focused run passed 87 tests with 1 optional test skipped and no failures. It covers additive histogram pixels, native traffic lights and header hit testing, crop/guide occlusion by the toolbar and filmstrip, guide tolerance/chrome/parallel-line solving, dehaze contrast, HDR/SDR export recipes, library settings, LCC post-processing, background jobs, invalid gain-map inputs, and SDR projection. The external Boston export test is opt-in and is skipped in this run.

Previous fork validation at `e5e077a` includes signed sandbox diagnostics and an interactive four-source panorama job that closed its window, exported HDR HEIC, and automatically imported the output. A separate full-resolution Boston export produced 21,304 × 15,368 pixels in 31.539 seconds. These measurements predate this upstream merge and are not substitutes for resolving the acceptance failures above.

## Distribution scope

The PR is available for maintainer review; it is not a claim that the complete suite passes or that a public release is ready. TestFlight preparation is maintained on the fork's separate distribution branch. No Apple distribution signature, upload, or tester invitation has occurred. Resolve or explicitly triage the remaining image/UI failures before broad external testing.
