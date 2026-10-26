#include <metal_stdlib>
using namespace metal;

// S3b — colour: eight HSL bands (Lightroom's red/orange/yellow/green/aqua/blue/purple/magenta),
// then vibrance, then global saturation.
//
// Hue bands overlap: each sample's band weight is a smooth tent of ±45° around the band centre, so
// moving one hue slider cannot produce a seam against its neighbour. Overlapping weights are
// renormalised, so a pixel sitting between two centres gets a blend rather than double the shift.
// Each band arrives as (hue, saturation, luminance, centreDegrees).
//
// Matte (派单 008 C): a *black* pixel survives this pass today because HSL keeps `l = 0` whatever
// the saturation does, so the matte happens to come out 0 — but that is an accident of the maths,
// not a rule, and the moment a hue band or a lift lands on a dark channel the bars tint. The
// content-rect guard is the rule, the same one S2 and S3a now carry.

struct ColorParams {
    float4 a;   // vibrance, saturation, identity, pad
    float4 b;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

static inline float3 rgb_to_hsl(float3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float l = (mx + mn) * 0.5;
    float d = mx - mn;
    if (d < 1e-6) {
        return float3(0.0, 0.0, l);
    }
    float s = l > 0.5 ? d / max(2.0 - mx - mn, 1e-6) : d / max(mx + mn, 1e-6);
    float h;
    if (mx == c.r) {
        h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
    } else if (mx == c.g) {
        h = (c.b - c.r) / d + 2.0;
    } else {
        h = (c.r - c.g) / d + 4.0;
    }
    return float3(h / 6.0, s, l);
}

static inline float hue_channel(float p, float q, float t) {
    if (t < 0.0) { t += 1.0; }
    if (t > 1.0) { t -= 1.0; }
    if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
    if (t < 0.5) { return q; }
    if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
    return p;
}

static inline float3 hsl_to_rgb(float3 hsl) {
    float h = fract(hsl.x);
    float s = clamp(hsl.y, 0.0, 1.0);
    float l = clamp(hsl.z, 0.0, 1.0);
    if (s < 1e-6) {
        return float3(l);
    }
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(hue_channel(p, q, h + 1.0 / 3.0),
                  hue_channel(p, q, h),
                  hue_channel(p, q, h - 1.0 / 3.0));
}

kernel void s3_color(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant ColorParams &p [[buffer(0)]],
                     constant float4 *bands [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.z > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Outside the content rect: the matte, written back unchanged.
    float2 g = float2(gid);
    if (g.x < p.b.x || g.y < p.b.y || g.x >= p.b.x + p.b.z || g.y >= p.b.y + p.b.w) {
        dst.write(c, gid);
        return;
    }

    // HDR headroom is carried around the HSL maths, not through it. `rgb_to_hsl` works on a
    // *normalised* colour (divide by the largest channel when it is above white), so a pixel at 4×
    // white keeps its 4× after the round trip: every clamp inside HSL is on the normalized values,
    // and the result is scaled back by the same factor. Before this, `clamp(c.rgb, 0, 1)` sat right
    // here, so touching vibrance or saturation flattened every highlight above white to 1.0 — the
    // picture lost its EDR range the moment a colour slider moved.
    // For an SDR pixel (max ≤ 1) the factor is exactly 1 and the maths below is bit-identical.
    float headroomScale = max(1.0, max(c.r, max(c.g, c.b)));
    float3 hsl = rgb_to_hsl(c.rgb / headroomScale);
    float hueDeg = hsl.x * 360.0;

    float3 shift = float3(0.0);
    float weightSum = 0.0;
    if (hsl.y > 1e-4) {
        for (int i = 0; i < 8; ++i) {
            float centre = bands[i].w;
            float d = abs(hueDeg - centre);
            d = min(d, 360.0 - d);
            float w = 1.0 - smoothstep(0.0, 45.0, d);
            shift += w * bands[i].xyz;
            weightSum += w;
        }
        if (weightSum > 1.0) {
            shift /= weightSum;
        }
    }

    hsl.x = fract(hsl.x + shift.x / 100.0 * (30.0 / 360.0));
    hsl.y = clamp(hsl.y * (1.0 + shift.y / 100.0), 0.0, 1.0);
    hsl.z = clamp(hsl.z * (1.0 + shift.z / 100.0), 0.0, 1.0);

    // Vibrance moves unsaturated pixels most: the gain scales with (1 - saturation), so skin tones
    // and already-saturated reds stay put while muted colour wakes up.
    float sat = hsl.y;
    if (abs(p.a.x) > 1e-6) {
        sat = clamp(sat + p.a.x / 100.0 * 0.5 * (1.0 - sat), 0.0, 1.0);
    }
    if (abs(p.a.y) > 1e-6) {
        sat = clamp(sat * (1.0 + p.a.y / 100.0), 0.0, 1.0);
    }
    hsl.y = sat;

    dst.write(float4(hsl_to_rgb(hsl) * headroomScale, c.a), gid);
}
