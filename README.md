# Photons

A native macOS RAW photo workflow app — library, non-destructive develop, export — written in
Swift, released under **MIT**.

It is not a port of darktable/RawTherapee, and it does not ship its own RAW decoder. It is built
**on Apple's RAW pipeline** (`CIRAWFilter`, RawCamera 9.x): the system's demosaic + machine-learning
denoise do the hard, camera-specific work; everything above that — catalog, editing graph, colour,
masking, export — is ours.

See [docs/architecture-decisions.md](docs/architecture-decisions.md) for the evidence behind every
architectural choice, including why LibRaw/Exiv2/libheif/lensfun are deliberately **not** used.

## Status

**M0 — acceptance harness.** There is no UI yet. What exists is the part that decides whether the
project can be built at all: a decode layer, a linear-buffer cache, and a verification chain that
fails loudly when Apple's decoder output changes.

```
make verify          # build + unit tests + L1 determinism + L2 golden image
make info RAW=…      # what the system reports about a file
make cache           # size and LRU eviction of the decoded linear buffers
```

## Requirements

- macOS 14+ (macOS 27 for the newest decoder versions)
- Xcode 26+/Swift 6
- A RAW or DNG sample of your own for the tests (`PHOTONS_TEST_RAW=…`)

No third-party dependencies. No `lensfun`, no `libraw`, no `exiftool`.

## Layout

```
Sources/PhotonsCore/       decode + linear buffer + cache (no UI, no AppKit)
Sources/photonsctl/        the acceptance harness CLI
Tests/PhotonsCoreTests/    determinism, version coverage, cache losslessness
Tests/Golden/              recorded pixel digests (per OS version)
docs/                      architecture decisions, status, task specs
```

## Licence

MIT. Third-party notices: none — the project links nothing outside the system frameworks.
