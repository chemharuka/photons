#include <metal_stdlib>
using namespace metal;

// The **luminance weights of the working primaries** — one place, for every kernel that needs a luma.
//
// 075 batch B. Until the working space moved to linear Rec.2020 these same three numbers
// (`0.2126, 0.7152, 0.0722`, BT.709) were written out in eight `.metal`/Swift files and in six tests.
// That is not a style problem: the weight is a *property of the primaries the numbers are in*, so a
// stale copy silently measures a different colour's brightness — Rec.709 weights reading Rec.2020
// codes are off by −13.4 % on saturated red, and Rec.2020 weights reading sRGB codes are off by
// **+23.57 %** (075 §5.2, `ColorPrimariesTests`). Neither shows up in a photograph's golden: on real
// content the mean |Δluma| of the swap is 0.00103.
//
// The Swift side reads `ColorPrimaries.working.luminanceWeights`; this header is the `.metal` copy of
// the same three constants, and `SaturatedColourTests.testTheKernelWeightsAreColorPrimaries` parses
// this file and asserts they are equal to that property — a kernel cannot import Swift, so the
// numbers have to exist twice, but they cannot *drift* twice.
//
// Deliberately not a `#define`: the value is used as a `float3` in a `dot`, and a typed constant is
// what makes the parse in the test unambiguous.
constant float3 kWorkingLumaWeights = float3(0.2627, 0.6780, 0.0593);
