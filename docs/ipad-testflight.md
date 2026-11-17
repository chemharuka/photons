# iPad private TestFlight beta

The iPad preview uses a separate App Store Connect record from the Mac app. It does not replace the Mac build or require an app login, subscription, or invitation-code implementation.

- App: **Photons Studio Preview**, Apple ID `6835653664`.
- Bundle ID: `com.leoaokma.photons.ipad-preview`.
- Initial beta: `0.1.0 (1)`, iPadOS 18+, iPad only, English startup.
- Release bundles include the app icon, privacy manifests, MIT/GRDB notices and the developer-created 43XL calibration. Private Boston RAW samples are explicitly excluded.
- Use a private external TestFlight group with public links disabled. Apple must approve the first external build through Beta App Review. Add only explicitly selected testers; creating a group does not send invitations.

## Distribution verification — 2026-11-16

The arm64 Release archive passed strict code-signature verification with an App Store distribution profile (`get-task-allow=false`, no device list). The executable and dSYM UUIDs match. The 48.7 MiB uncompressed app contains the 43XL calibration, privacy manifests, MIT/GRDB notices and an opaque 1024 px icon, with no bundled Boston RAWs. Xcode reported **Upload succeeded** for `0.1.0 (1)` at 18:35 EST. Apple completed server processing, and the build was submitted to external **Private Beta**; its status is **Waiting for Review**. External automatic tester notifications are disabled. No testers have been invited. Upload success and server processing do not mean Beta App Review approval.

The same build is **Ready to Test** in the internal **Developer Beta** group. Both groups currently have zero testers; internal automatic distribution is off, and the external group has no public link. Review status can be checked in [App Store Connect](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835653664/testflight).

The functional engine/UI checks are recorded in [iPad preview validation](reports/ipad-preview-validation.md); this distribution follow-up changes packaging and signing only. Physical iPad performance, memory and HDR display behaviour remain the subject of this beta.

## Reproduce the archive

Install an App Store Connect provisioning profile matching this Bundle ID and a locally available Apple Distribution certificate. An iOS App Development profile is not needed for the distribution archive; automatic development provisioning may fail when the team has no registered devices.

```sh
xcodebuild -project Apps/iPad/PhotonsIPad.xcodeproj \
  -scheme 'Photons iPad Preview' -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath .build/ipad-device \
  -archivePath '.build/ipad-testflight/Photons iPad Preview.xcarchive' \
  -disableAutomaticPackageResolution -skipPackageUpdates archive \
  PHOTONS_INCLUDE_BOSTON_SAMPLES=NO \
  PHOTONS_IPAD_SIGN_STYLE=Manual \
  PHOTONS_IPAD_SIGN_IDENTITY='Apple Distribution' \
  PHOTONS_IPAD_PROFILE='YOUR INSTALLED APP STORE PROFILE'
```

The custom signing variables apply only to the app's Release configuration. Passing `PROVISIONING_PROFILE_SPECIFIER` globally would incorrectly assign the app profile to SwiftPM resource bundles. Debug keeps automatic development signing.

Use a local, ignored export-options plist with `method=app-store-connect`, `destination=upload`, `signingStyle=manual`, the team/certificate and a `provisioningProfiles` mapping for the app. Keep `manageAppVersionAndBuildNumber=false` and `uploadSymbols=true`. With Xcode signed in:

```sh
xcodebuild -exportArchive \
  -archivePath '.build/ipad-testflight/Photons iPad Preview.xcarchive' \
  -exportOptionsPlist .build/ipad-testflight/ExportOptions.plist \
  -exportPath .build/ipad-testflight/upload -allowProvisioningUpdates
```

Increment `CURRENT_PROJECT_VERSION` for each subsequent upload. Before uploading, verify the archive's version, iPad-only device family, distribution entitlements, opaque 1024 px icon, licenses/profile resource and absence of bundled `.3FR` files. Signing material and account contacts must stay outside Git. Check Apple's processing status separately from the upload result.

## Beta App Description — English

Photons Studio Preview brings local RAW photo editing, HDR/SDR preview and export, panorama stitching, and lens cast correction (LCC) to iPad. This early private beta uses the same processing engines as the Mac version with a touch interface. Import photos from Files, edit in a local library, stitch overlapping images, and export or share results. A developer-created 43XL lens profile is included. No app account or subscription is required. iPadOS 18 or later is required.

## What to Test — English

- Import RAW, DNG, TIFF and HEIF images from Files; check thumbnails, orientation, preview generation and duplicate handling.
- Pinch the photo grid, tap to toggle the inspector, and long-press to select multiple images.
- Test editing, HDR/SDR preview, histograms, undo and restoring the imported state.
- Select overlapping photos, choose Shift or Perspective panorama, inspect the full-screen preview and try the draggable source positions and four body orientations.
- Test matching-flat and lens-profile LCC. For shift panoramas, compare full-frame output with Crop to corrected area enabled.
- Export HDR/SDR images and lossless linear DNG, verify automatic library import, and save/share through Files.
- Report your iPad model, iPadOS version, photo format, image dimensions and reproduction steps, including crashes, memory pressure and slow operations.

This preview exports up to 6000 px on the long edge. Full-resolution large exports, background recovery and several desktop tools are still being adapted. Use copies of valuable photos; processing currently requires the app to stay active.

## Beta Review Notes — English

No login, subscription or invitation code is required inside the app. All photo processing is local. Tap + to import photos from Files. Tap a photo for its inspector; long-press a photo and tap additional images to select multiple photos, then tap the panorama toolbar icon. Choose Shift panorama for lens/back movement captures or Perspective panorama for modest changes in camera direction. The gear button opens full-screen settings and lens-profile management. The supplied 43XL calibration is optional; no private source photographs are bundled. Export supports 2048, 4096 or 6000 px long edge and saves into the app library with Files sharing available. This is an iPad-only development beta; desktop external AI-denoise and exposure-stack HDR helpers are not bundled.
