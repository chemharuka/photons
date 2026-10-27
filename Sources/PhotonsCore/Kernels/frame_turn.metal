#include <metal_stdlib>
using namespace metal;

// **One turn, two stages** (派单 080).
//
// `s0_geometry` (the picture) and `s1_5_mask_atlas` (the selection) both have to rotate about the
// frame's centre by the document's straighten angle. If they rotate in different spaces the mask
// slides off the pixels it selects — silently, because both are "rotated by θ" and each is
// internally consistent.
//
// That is exactly what happened. Rotating `uv − ½` is a rotation of *normalised* coordinates: the x
// offset is divided by the frame's width and the y offset by its height, so `R(θ)` is followed by the
// non-uniform scale `× frameSize` and the composite is `rotation ∘ anisotropic scale` — a **shear**
// whose factor is the frame's W/H (1.5 for a 3:2 frame, 0.667 the other way for a portrait one). At
// 7° on a 9504×6336 photograph it is 273 px at the corner.
//
// 073 fixed S0 (the picture) by turning *pixels*. 080 fixed the atlas, which had kept the old
// convention: the mask's own rotation was still `rot(θ) ∘ aniso(W/H)`, so a straightened photo showed
// one picture and selected another. The lesson is in `tests` as well as here — a test that re-derives
// the kernel's coordinates instead of measuring where the mask lands against the picture cannot see
// this at all (`MaskTests.testAtlasInvertsCropRotationAndFlip` used to do precisely that).
//
// So: the turn is applied to a **pixel offset about the frame's centre**, and it is applied by this
// one function. `s0_geometry` and `s1_5_mask_atlas` include this file, so the two cannot drift back
// into two conventions by editing one of them.
//
// The inverse (source → canvas) is `frame_turn_pixels(offsetPx, cs, -sn)`, and the host's
// `MaskCanvasMapping.canvasPoint` is the same arithmetic in `Double`.
//
// Deliberately dependency-free and `static inline`: the two kernels carry it into two different
// instantiations (rotating / not rotating) and a header that pulled in anything else could change
// code generation for the non-rotating path, which is where byte identity lives.
static inline float2 frame_turn_pixels(float2 offsetPx, float cs, float sn) {
    return float2(offsetPx.x * cs - offsetPx.y * sn, offsetPx.x * sn + offsetPx.y * cs);
}
