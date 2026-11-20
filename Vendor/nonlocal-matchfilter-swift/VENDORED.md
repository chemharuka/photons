# nonlocal-matchfilter-swift — vendored

Source copy of https://github.com/chemharuka/nonlocal-matchfilter-swift at commit
`102f698` ("strength follows the measured noise, and strips can be lossless JPEG").

Photons builds it as a **local SwiftPM package** (`Package.swift` →
`.package(path: "Vendor/nonlocal-matchfilter-swift")`) so a checkout needs no
sibling clone. Same arrangement as `Vendor/ansel-denoise-swift`.

## What is here, and what is not

Everything the library target needs: `Package.swift`, `Sources/`, `Tests/`,
`docs/`, `Scripts/`, `README.md`, `LICENSE`.

`Models/` is **not** vendored — it is 330 MB (two `.mlpackage` plus the `.pt`
weights and compiled caches) and Photons already ships the one model it uses at
`Sources/PhotonsExtensions/Denoise/Models/v_matmul_256.mlpackage`. Consequence:
`swift test` inside this directory cannot run `BundledModelTests` (it looks for
`Models/`); the Photons test suite does not build this package's tests, and the
`nlmf-denoise` executable works as long as a model is passed explicitly.

## Syncing

From the library checkout, with the commit you want to vendor:

```sh
rsync -a --exclude .build --exclude .git --exclude Models \
  ~/Documents/GitHub/nonlocal-matchfilter-swift/ \
  ~/Documents/GitHub/photons/Vendor/nonlocal-matchfilter-swift/
```

then update the commit hash above and commit the diff in Photons.

## Why a copy at all

The denoiser is MIT, so it links in-process; vendoring keeps the build
reproducible and offline. The alternative — a remote `.package(url:)`
requirement — would need a published version tag, and this library is not
released yet (no tag; `1.0.0` was retracted).
