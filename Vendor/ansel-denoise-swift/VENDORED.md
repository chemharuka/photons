# ansel-denoise-swift — vendored

Source copy of https://github.com/chemharuka/ansel-denoise-swift at commit
`f0667cd` ("feat(blend): 564 — gate 0.35 / knee 1.00–1.40 / 128×2 smoothing (less visible)").

This tool is **GPL-3.0**, so unlike the MIT denoiser next door it is *not* linked
into Photons. It is built to its own executable and driven over a pipe
(`AnselDenoiseClient`); Photons ships that binary at
`Photons.app/Contents/Resources/bin/ansel-denoise-swift`. The copy here is the
source of record for what that binary was built from — it does not take part in
the app build.

## What is here

`Package.swift`, `Sources/`, `Tests/`, `Host/` (the host-side client this repo
mirrors), `docs/`, `scripts/`, `weights/` (the 1.8 MB quarter model used by the
tests), `README.md`, `PROTOCOL.md`, `PORTING.md`, `LICENSE`, `LICENSE-SCOPE.md`.

`local/` is excluded: by this repo's convention it holds RAW fixtures and session
scratch that must not be published (268 MB of it in the source checkout).

## Syncing

```sh
rsync -a --delete --exclude .build --exclude .git --exclude .DS_Store \
  --exclude local --exclude out --exclude .cache \
  ~/Documents/GitHub/ansel-denoise-swift/ \
  ~/Documents/GitHub/photons/Vendor/ansel-denoise-swift/
```

then update the commit hash above and commit the diff.

Last synced: 2026-11-26 (`f0667cd`).
