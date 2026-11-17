43XL + iiic / Hasselblad CFV 100C / f/11 / infinity
All profiles currently supplied with Photons are user-generated calibration files,
created and shared by the developer acting as a user, not official/certified lens profiles.
They use the same readable, unencrypted format as other user profiles and may be
viewed, copied, imported and exported. Installing an app update does not replace an
existing user copy. Importing a profile with the same ID requires explicit replacement.
Measured 2026-11-15. 36 landscape and 9 counterclockwise portrait LCC captures.
The built-in .photonslcc contains oriented Float32 CFA block means, their standard
errors, cell coordinates, shifts, sensor size and capture conditions. It keeps the
full illuminated sensor footprint, including dark corners. No original RAW image,
absolute source path or private EXIF serial number is included.

The application copies this calibration into Application Support/Photons/LensProfiles
on first use. User-created profiles live there too. A profile is a losslessly compressed
binary property list with a versioned JSON catalog header and SHA-256 integrity digest.

CFA data and Apple-developed linear-sRGB data have distinct measurement-space IDs.
They must not be mixed or applied in the wrong processing space. Automatic orientation
selection is separate from determining the absolute optical position and applying LCC.

The built-in file also retains the original fixed-6500K linear-sRGB measurements for
archival compatibility; they are no longer applied to RAW pixels. Runtime uses the
four black-subtracted CFA channels. The v1 CFV 100C grid's 4094 DN subtraction is
adjusted by 2 DN to agree with the file's 4096 DN black tag. New profiles use v2,
normalized black-subtracted CFA means and standard errors, without storing RAW files.
PHLCC002 losslessly shuffles Float32 bit deltas before LZFSE; grids round-trip exactly.

Spatial falloff and colour shading are corrected completely. A single global EV
changes panorama brightness after this correction; there is no partial falloff slider.
A temporary Bayer DNG carries four maps through OpcodeList2 before Apple demosaic,
WB and colour conversion. Apple requires equal green maps, so the small G1/G2 ratio
is applied to the mosaic first, then a shared geometric-mean green map is used.
The original camera matrices and calibration metadata remain in the intermediate DNG.
Explicit shadowBias=0 is essential: Apple's default shadow subtraction otherwise
breaks linearity and creates dark seams at different normalizations. Normalization
before RAW processing is reversed in floating point after development.

WB is measured after spatial correction, preferentially from confirmed paired white
plates; without them, bright scene pixels give an estimate that the user can override.
It is never a fitted RGB tint to compensate for a colour cast. Profile illumination
cancels independently per channel against its central reference. A partial profile
without the optical axis uses its brightest measured reference, so an absolute global
colour offset cannot be identified from that profile alone.

Original sensor clipping is tracked separately from LCC overexposure. Saturated
channels are estimated from surviving channels and neighbouring unsaturated colours
(with measured illumination as fallback); this cannot
restore lost information or guarantee original saturated colours. One panorama exposure
and an SDR shoulder protect displayed highlights; the linear DNG export retains headroom.
No spatial RGB overlap fitting is applied on top of LCC. Only scalar overlap exposure
matching remains. Gain coordinates, WB and geometry are frozen for full export.

The native mosaic path currently supports uncompressed CFV 100C 3FR and compatible
16-bit little-endian Bayer DNG (uncompressed or supported SOF3 tiles). Unknown RAW
layouts, linearization and extra pixel-calibration opcodes are rejected explicitly.
No LibRaw or other additional dependency is linked. Export remains a developed linear
RGB DNG, not a camera-CFA DNG with its original editable capture WB metadata.

A measured frame is the sole absolute position anchor. Additional measured positions
seed bounded (+/-1.5 mm) translation searches; image correlation must still succeed.
Body travel is independent of EXIF sensor orientation. Supported Alpa bodies (mm):
Max: L/R 18, U 25, D 18; XY: L/R 25, U 45, D 25; STC: L/R 18, U/D 0;
Pano: L/R 35, U/D 10; Plus: L/R/U/D 20. Placement angles are counterclockwise in
image-plane right/up coordinates. Max/XY expose 0/90/180/270; symmetric travel is
deduplicated to 0/90 for STC/Pano and 0 for Plus. The diagram, out-of-travel warnings
and optical solver share these rotated ranges. Sensor footprints retain their own
RAW orientation. With no established optical origin the total coverage box remains
centered on the panorama; with an anchor, its asymmetry is relative to shift zero.
An automatic optical-origin search uses confirmed paired white plates when available;
otherwise scene colors/shading give only a low-confidence proposal for visual review.
Paired plates determine corrected WB and aid location; they do not stack another
spatial correction on top of the selected lens profile.

Schema 2 profiles record the calibration body and each white plate's body placement.
Grids, sensor extents and shifts are normalized to body coordinates on creation;
the orientation variant describes sensor orientation RELATIVE to the body. User-entered
H/V positions are in image right/up coordinates and are inverse-rotated on save.
Matching subtracts body rotation from EXIF rotation; runtime gain sampling, coverage,
cropping, optical solving and manual alignment rotate the field into image coordinates.
This preserves the native CFA correction when body and back rotate together.
Per the supported-body symmetry convention, equivalent travel placements may reuse
the corresponding rotated LCC variant. Prefer a measured exact variant when present.
Body model is recorded as provenance, not an optical restriction across camera bodies.
Schema 1 profiles remain readable as body-0 measurements; the bundled 43XL profile
was measured on an Alpa 12 Max at 0 degrees. No original calibration RAW is embedded.
