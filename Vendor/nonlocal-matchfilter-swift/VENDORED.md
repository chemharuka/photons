# nonlocal-matchfilter-swift - vendored

Source copy of https://github.com/chemharuka/nonlocal-matchfilter-swift at commit
`694d505` ("strength: re-anchor sigma to the current estimator (192-frame rescan)").

Photons builds it as a **local SwiftPM package** (`Package.swift` ->
`.package(path: "Vendor/nonlocal-matchfilter-swift")`) so a checkout needs no
sibling clone: building Photons builds the plugin too.

## What is here

Only what the build needs:

    Package.swift
    Sources/NonlocalMatchFilter/    the library
    Sources/nlmf-denoise/           its CLI (kept: the manifest declares it)
    LICENSE

`Tests/`, `docs/`, `Scripts/` and `Models/` are **not** copied.
`Models/` alone is 330 MB, and Photons already ships the one weight it uses at
`Sources/PhotonsExtensions/Denoise/Models/v_matmul_256.mlpackage`.

The library's manifest declares its test target only when `Tests/` exists, which
is what lets this tree build without carrying the tests.

## Syncing

```sh
V=~/Documents/GitHub/photons/Vendor/nonlocal-matchfilter-swift
rm -rf "$V"/Package.swift "$V"/Sources "$V"/LICENSE
cp   ~/Documents/GitHub/nonlocal-matchfilter-swift/Package.swift "$V"/
cp -R ~/Documents/GitHub/nonlocal-matchfilter-swift/Sources "$V"/
cp   ~/Documents/GitHub/nonlocal-matchfilter-swift/LICENSE "$V"/
```

Then update the commit hash above and commit the diff in Photons.
