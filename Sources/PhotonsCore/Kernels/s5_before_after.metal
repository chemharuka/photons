#include <metal_stdlib>
using namespace metal;

// S5 — 前后对比 composite (派单 080).
//
// Two **already display-encoded** frames of the same canvas go in; one comes out, split at a
// draggable line. This pass is deliberately the dumbest thing that can work:
//
//   · it reads, it writes, it does not convert — both inputs are S4's output, so there is no
//     matrix, no transfer function and no headroom here, and the composite of two identical frames
//     is byte-identical to either of them (a "does compare change the picture" question that has an
//     answer, not an intuition);
//   · the boundary is a **pixel index** handed in by the caller (`CompareSplit.dividerPixel`), not a
//     fraction, so the line cannot land on a different column than the one `CompareSplit.side(x:y:)`
//     says owns it. The GPU never re-derives the arithmetic;
//   · the line itself is painted, not blended: a 2-px column (row) of 0.5 code. A pixel of the line
//     belongs to neither source, which is why `CompareSide.divider` exists — a reader that samples
//     the boundary gets "the line", not a lucky sample of one of the two pictures.
//
// What it deliberately does **not** do: touch a document, a cache key or the stage cache. This pass
// runs after both frames exist, over textures the graph already produced, so entering, dragging and
// leaving 对比 cannot move a single stage's key — which is the property 「拖动分界线不写文档」 rests on
// (`BeforeAfterTests`, `BeforeAfterUITests`).

struct CompareParams {
    float4 a;   // divider pixel index, axis (0 = vertical/left-right, 1 = horizontal/top-bottom),
                // line width in pixels, pad
};

kernel void s5_before_after(texture2d<float, access::read> before [[texture(0)]],
                            texture2d<float, access::read> after  [[texture(1)]],
                            texture2d<float, access::write> dst   [[texture(2)]],
                            constant CompareParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
    // `CompareSplit.side(x:y:canvas:)`, in the same units: an index on the split axis.
    int idx = int(p.a.y < 0.5 ? gid.x : gid.y);
    int d = int(p.a.x);
    int lineWidth = max(int(p.a.z), 0);
    int first = d - lineWidth / 2;
    if (lineWidth > 0 && idx >= first && idx < first + lineWidth) {
        dst.write(float4(0.5, 0.5, 0.5, 1.0), gid);
        return;
    }
    dst.write(idx < d ? before.read(gid) : after.read(gid), gid);
}
