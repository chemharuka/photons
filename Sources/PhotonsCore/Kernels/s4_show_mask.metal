#include <metal_stdlib>
using namespace metal;

// S4.5 — `showMask`: the selected mask painted over the finished frame.
//
// docs/tasks/005-masks.md §3.1: the atlas "is also the data source of the `showMask` overlay — one
// implementation, two exits". So this pass reads the **same** `texture2d_array` S1.6 consumed (same
// slice index, same coverage, feather/refine already applied) and never re-evaluates the predicate.
// That is the whole point: an overlay drawn from a second evaluation would one day disagree with the
// adjustment it is previewing, and the disagreement would look like a mask bug.
//
// Where it sits: **after** S4, on the display-encoded frame, because the overlay is a UI affordance
// and not an edit — it must not be tone-mapped, and it must not enter any stage's cache key except
// the display link (`EditModel.showMaskID`).
//
// The blend is `mix(image, red, 0.5 · coverage)` in the encoded space, i.e. a 50 % red wash whose
// opacity follows the coverage. Red is (1, 0, 0) in whatever primaries S4 wrote, which is red in
// every one of them (a primary). No alpha is touched: the mask is painted, the photograph's opacity
// is not.
//
// Cost: one full-canvas pointwise pass with two reads — measured in `MaskSemanticTests` alongside the
// rest of the frame, not estimated.

struct ShowMaskParams {
    int4   a;   // slice, pad, pad, pad
    float4 b;   // strength (0…1), red.r, red.g, red.b
};

kernel void s4_show_mask(texture2d<float, access::read> src [[texture(0)]],
                         texture2d_array<float, access::read> atlas [[texture(1)]],
                         texture2d<float, access::write> dst [[texture(2)]],
                         constant ShowMaskParams &p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) { return; }

    float4 c = src.read(gid);
    int slice = max(p.a.x, 0);
    // A slice index out of range is not a picture, it is a bug upstream; painting nothing is the
    // only honest answer (and the graph never asks for one — it resolves the id first).
    if (slice >= int(atlas.get_array_size())) {
        dst.write(c, gid);
        return;
    }
    float a = clamp(atlas.read(gid, uint(slice)).r, 0.0, 1.0) * clamp(p.b.x, 0.0, 1.0);
    dst.write(float4(mix(c.rgb, p.b.yzw, a), c.a), gid);
}
