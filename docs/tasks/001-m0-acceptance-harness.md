# Task 001 — M0 acceptance harness

**Status:** done · **Owner session:** `s-20261025-2020-2a33` · **Format:** retrospective spec
(this was written as it was built; later tasks are written before the work)

## Goal

Make the project verifiable before it is interesting. No UI, no catalog: prove that Apple's RAW
pipeline can be driven from Swift, that its output is reproducible, and that a changed output is
detected loudly rather than shipped.

## Deliverables

| File | Purpose |
|---|---|
| `Sources/PhotonsCore/LinearImage.swift` | linear RGBA half buffer + SHA-256 + statistics + box downscale |
| `Sources/PhotonsCore/RAWDecoder.swift` | `CIRAWFilter` driver: probe, version selection, render to `rgba16Float` texture |
| `Sources/PhotonsCore/LinearImageStore.swift` | on-disk linear cache, atomic write, LRU eviction, full-file SHA-256 |
| `Sources/photonsctl/main.swift` | `info` `hash` `decode` `golden` `cache` |
| `Tests/PhotonsCoreTests/DecodeTests.swift` | 6 tests (see acceptance) |
| `Makefile` | `verify` = build + tests + L1 + L2 |

## Acceptance (all executed, output recorded)

```
make verify
  ✔ 6/6 unit tests
  ✔ L1 determinism   two independent processes, identical digest
  ✔ L2 golden        Tests/Golden/L1030433-v8-s1.0.json
  ALL GREEN
```

Per-version digests for `L1030433.dng @ scale 0.125` (each version decoded twice, equal; versions
differ from each other):

```
v6.dng 86435b85b90b…   v7    f278601e030f…   v7.dng ff671e8cb36a…
v8     8182b6e6cb25…   v8.dng 6eea43c04a4d…  v9.dng ff4193f22edc…
```

## Constraints respected

- zero third-party dependencies; system frameworks only (`CoreImage`, `ImageIO`, `Metal`, `CryptoKit`)
- MIT
- no RAW files committed; fixtures come from `PHOTONS_TEST_RAW`
- no research material committed; it lives in `local/` (see `local/README.md`)

## Pitfalls found while building (worth remembering)

1. `CGColorSpace(name:)` takes the **CFString constant** value. Passing the friendly string
   `"extendedLinearSRGB"` returns nil, and a failable initialiser turned that into a misleading
   "no Metal device" error. Fixed by an enum mapping to the real constants.
2. `CIContext.createCGImage` does **not** wait for the GPU. Timing it produced a fake
   11 859 Mpx/s. Always `render(to: MTLTexture)` + `waitUntilCompleted()`.
3. Decoder versions are per-file, not per-system: a DNG offers `9.dng` while a non-DNG body may
   offer `9`. Always resolve against `supportedDecoderVersions` and reject loud otherwise.
4. `.shared` storage for the render target keeps M0 simple; it costs bandwidth at 60 MP and is
   replaced in M1 by a private texture + `MTLBuffer` blit.

## Follow-ups created

- `docs/tasks/002-editing-graph.md` — M1
- the golden baseline is OS-version sensitive: `GoldenRecord.osVersion` exists so a macOS update
  failure is distinguishable from a regression
