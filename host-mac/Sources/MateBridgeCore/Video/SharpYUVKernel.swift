import Foundation

/// Metal source of the T-235 chroma pass (`SharpYUV` is its CPU reference; keep the two in step). Compiled at run time
/// by the host's `ChromaConverter` (no resource bundle to ship) and by XCTest, which runs it on plain textures and
/// compares it with `SharpYUV.convert`.
///
/// Two kernels, dispatched in order in one command buffer:
/// - `sharp_chroma`: one thread per chroma sample: 2x2 box mean of Cb'/Cr' -> `rg8Unorm` (Cb, Cr codes).
/// - `sharp_luma`: one thread per pixel -> `r8Unorm` Y code; buffer 0 `mode` (0 = plain Y', 1 = adjusted for bilinear
///   chroma upsampling, 2 = adjusted for nearest), buffer 1 the EOTF table (`SharpYUV.eotfTable`, `eotfTableSize`
///   floats).
/// The source texture is `bgra8Unorm` holding sRGB-encoded values (not `_srgb`: no conversion on read).
/// Compile with safe math (`MTLCompileOptions.mathMode = .safe`) so division and rounding stay close to the CPU.
public enum SharpYUVKernel {
    public static let chromaFunction = "sharp_chroma"
    public static let lumaFunction = "sharp_luma"

    /// `sharp_luma`'s `mode` buffer value: nil upsampling = plain Y'.
    public static func lumaMode(_ adjustFor: SharpYUV.Upsample?) -> UInt32 {
        switch adjustFor {
        case nil: return 0
        case .bilinear?: return 1
        case .nearest?: return 2
        }
    }

    public static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float KR = 0.2126f, KG = 0.7152f, KB = 0.0722f;
    constant float CR_R = 1.5748f, CB_G = 0.187324f, CR_G = 0.468124f, CB_B = 1.8556f;
    constant int LUT_SIZE = \(SharpYUV.eotfTableSize);

    static inline float to_linear(float v, device const float *lut) {
        float c = clamp(v, 0.0f, 1.0f) * float(LUT_SIZE - 1);
        int i = min(int(c), LUT_SIZE - 2);
        float f = c - float(i);
        return lut[i] + f * (lut[i + 1] - lut[i]);
    }

    static inline float luminance(float3 p, device const float *lut) {
        return KR * to_linear(p.r, lut) + KG * to_linear(p.g, lut) + KB * to_linear(p.b, lut);
    }

    static inline float rebuilt(int y_code, float cb, float cr, device const float *lut) {
        float y = float(y_code) / 255.0f;
        float3 p = clamp(float3(y + CR_R * cr, y - CB_G * cb - CR_G * cr, y + CB_B * cb), 0.0f, 1.0f);
        return luminance(p, lut);
    }

    // Smallest code whose rebuilt luminance reaches `target` (255 when none does), found by galloping out from `g`
    // and bisecting the bracket. The luminance is monotonic in the code, so the result does not depend on `g` and
    // equals the CPU reference's plain bisection. `lc` = L(code), `lprev` = L(code - 1) (when code > 0).
    static inline int reach(float target, float cb, float cr, int g, device const float *lut,
                            thread float &lc, thread float &lprev) {
        int lo, hi;
        float llo1 = 0.0f, lhi = 0.0f;
        float lg = rebuilt(g, cb, cr, lut);
        if (lg >= target) {
            hi = g; lhi = lg; lo = 0;
            int step = 1;
            while (hi > 0) {
                int t = max(g - step, 0);
                float lt = rebuilt(t, cb, cr, lut);
                if (lt < target) { lo = t + 1; llo1 = lt; break; }
                hi = t; lhi = lt;
                step *= 2;
            }
        } else {
            lo = g + 1; llo1 = lg; hi = 255;
            int step = 1;
            bool found = false;
            while (lo <= 255) {
                int t = min(g + step, 255);
                float lt = rebuilt(t, cb, cr, lut);
                if (lt >= target) { hi = t; lhi = lt; found = true; break; }
                lo = t + 1; llo1 = lt;
                step *= 2;
            }
            if (!found) {
                lc = llo1;
                lprev = rebuilt(254, cb, cr, lut);
                return 255;
            }
        }
        while (lo < hi) {
            int mid = (lo + hi) / 2;
            float lm = rebuilt(mid, cb, cr, lut);
            if (lm < target) { lo = mid + 1; llo1 = lm; } else { hi = mid; lhi = lm; }
        }
        lc = lhi;
        lprev = llo1;
        return lo;
    }

    static inline float2 chroma_code(texture2d<float, access::read> cbcr, int i, int j) {
        int cw = int(cbcr.get_width()), ch = int(cbcr.get_height());
        uint2 p = uint2(uint(clamp(i, 0, cw - 1)), uint(clamp(j, 0, ch - 1)));
        return round(cbcr.read(p).rg * 255.0f);
    }

    kernel void sharp_chroma(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> cbcr [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= cbcr.get_width() || gid.y >= cbcr.get_height()) return;
        uint w = src.get_width(), h = src.get_height();
        float cb = 0.0f, cr = 0.0f;
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 p = uint2(min(2 * gid.x + dx, w - 1), min(2 * gid.y + dy, h - 1));
                float3 c = src.read(p).rgb;
                float yp = KR * c.r + KG * c.g + KB * c.b;
                cb += (c.b - yp) / CB_B;
                cr += (c.r - yp) / CR_R;
            }
        }
        float2 code = clamp(floor(float2(cb, cr) * 0.25f * 255.0f + 128.0f + 0.5f), 0.0f, 255.0f);
        cbcr.write(float4(code / 255.0f, 0.0f, 0.0f), gid);
    }

    kernel void sharp_luma(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::read> cbcr [[texture(1)]],
                           texture2d<float, access::write> luma [[texture(2)]],
                           constant uint &mode [[buffer(0)]],
                           device const float *lut [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= luma.get_width() || gid.y >= luma.get_height()) return;
        float3 c = src.read(gid).rgb;
        int y0 = int(clamp(floor((KR * c.r + KG * c.g + KB * c.b) * 255.0f + 0.5f), 0.0f, 255.0f));
        int out = y0;
        if (mode != 0) {
            int i = int(gid.x >> 1), j = int(gid.y >> 1);
            float2 v;
            bool uniform;
            float2 a = chroma_code(cbcr, i, j);
            if (mode == 2) {
                v = a;
                uniform = true;
            } else {
                int ni = (gid.x & 1) == 0 ? i - 1 : i + 1;
                int nj = (gid.y & 1) == 0 ? j - 1 : j + 1;
                float2 b = chroma_code(cbcr, ni, j), c2 = chroma_code(cbcr, i, nj), d = chroma_code(cbcr, ni, nj);
                v = (9.0f * a + 3.0f * b + 3.0f * c2 + d) / 16.0f;
                uniform = all(a == b) && all(a == c2) && all(a == d);
            }
            // Flat: the decoder sees this pixel's own chroma; keep the plain code (skips the search).
            float yp = KR * c.r + KG * c.g + KB * c.b;
            float2 own = clamp(floor(float2((c.b - yp) / CB_B, (c.r - yp) / CR_R) * 255.0f + 128.0f + 0.5f),
                               0.0f, 255.0f);
            if (uniform && all(own == a)) {
                luma.write(float4(float(y0) / 255.0f, 0.0f, 0.0f, 0.0f), gid);
                return;
            }
            float cb = (v.x - 128.0f) / 255.0f, cr = (v.y - 128.0f) / 255.0f;
            float target = luminance(c, lut);
            // One secant step from the plain code gives a guess, usually within a code of the answer.
            float l0 = rebuilt(y0, cb, cr, lut);
            int dir = l0 < target ? 1 : -1;
            int y1 = clamp(y0 + dir, 0, 255);
            float slope = (rebuilt(y1, cb, cr, lut) - l0) * float(dir);
            int guess = y0;
            if (slope > 0.0f) { guess = int(clamp(rint(float(y0) + (target - l0) / slope), 0.0f, 255.0f)); }
            float lc, lprev;
            int code = reach(target, cb, cr, guess, lut, lc, lprev);
            if (code > 0 && target - lprev <= lc - target) { code -= 1; }
            out = code;
        }
        luma.write(float4(float(out) / 255.0f, 0.0f, 0.0f, 0.0f), gid);
    }
    """
}
