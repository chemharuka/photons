# Post-stitch HDR HEIC correction and position references

## Observed failure

The user's `gui-export/B0000659_pano.heic` is a 20,000 × 14,424 HDR gain-map HEIC with a legacy panorama manifest. It records four source rectangles, seam masks, white balance and exposure gains, but neither an absolute optical origin nor the local RGB compensation baked in before blending.

The displayed estimate placed the upper row at about +19.9 mm. The user confirmed that the upper row was at the Alpa's +25 mm stop. Relative registration cannot establish this absolute vertical anchor from geometry alone, and scene-color minimization can favor an incorrect origin. The current screenshot had manual positioning unchecked; the displayed coordinates came from the scene estimate.

An independent Core Image read of this exact file also confirmed that the panorama/LCC decoder was reading the SDR base. At a 512-pixel inspection scale, its maximum RGB values were about 0.97; requesting HDR expansion recovered values up to about 2.74. This is a decoding defect, not a missing HDR payload in the file.

## Changes

- Non-RAW panorama/LCC decoding now expands HDR gain maps. Correction and position estimation operate on the reconstructed linear image.
- Manual positioning supports either a source-frame center or the visible output-picture center. The latter includes the saved crop and output transform. Switching references preserves placement; enabling manual positioning starts from the displayed estimate rather than stale pre-solve fields.
- Overlap correction inverts the weighted lens responses instead of averaging correction gains. For a common linear scene signal, the gain is `sum(w * exposure) / sum(w * exposure * photometry / lensGain)`, per channel.
- New panorama manifests retain a compact, sampled RGB compensation field for each source. Post-correction removes this recorded compensation; position estimation removes it from source-dominated samples. Legacy manifests remain readable. Optional fields are validated before use.
- The sidebar identifies scene positions as estimates and explicitly recommends stitching originals again with LCC applied before blending. Older files without compensation records receive an additional explanation. Both languages are covered.

## Validation

27 distinct focused tests pass across the initial run and corrective reruns. A release build also succeeds. The synthetic mixed-orientation fixture initially rewrote its own source file and correctly triggered the source-identity guard; it now writes its observation to a separate file and passes. Two opt-in external-fixture/generation tests were skipped.

Coverage includes HDR gain-map decoding, a synthetic forward blend with different orientation-dependent shading and RGB compensation, metadata round trips and malformed-field rejection, crop/rotation geometry, reference switching, CFA correction, profile compatibility and panorama provenance.

The actual GUI HEIC was decoded and corrected using the user's vertical anchor. Its highest source center is +25 mm; the visible picture center is approximately +12.565 mm. Horizontal position was held at a zero optical-origin offset for this diagnostic and is not a measured horizontal ground truth. The original file was not modified. Fixed-exposure comparison PNGs remain under `local/audit/post-lcc-heic-fix/` and are not committed.

Visual inspection shows reduced falloff, with residual local sky color still visible. This is not a claim of exact equivalence to correcting the RAW sources. The old file's missing compensation, baked-in white balance/color processing, blending, compression and clipped sensor data cannot all be reversed by an RGB gain field. The new recorded fields are also sampled approximations.

These checks do not supersede the unresolved full acceptance failures documented in [fork-integration-validation.md](fork-integration-validation.md).
