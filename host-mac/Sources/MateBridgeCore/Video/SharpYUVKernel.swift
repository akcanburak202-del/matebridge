import Foundation

/// Metal source of the T-235 chroma pass (`SharpYUV` is its CPU reference; keep the two in step). Compiled at run time
/// by the host's `ChromaConverter` (no resource bundle to ship) and by XCTest, which runs it on plain textures and
/// compares it with `SharpYUV.convert`.
///
/// One fused kernel (T-311, decision 0033), one dispatch, no barrier between chroma and luma: `sharp_fused` runs one
/// thread per 2x2 block. It reads the block's four pixels once, writes the block's chroma sample (2x2 box mean of
/// Cb'/Cr' -> `rg8Unorm`, the Cb and Cr codes) and then the four luma codes (`r8Unorm`) from the chroma code it just
/// computed (buffer 0 `mode`: 0 = plain Y', 1 = adjusted for nearest chroma upsampling; buffer 1 the EOTF table
/// `SharpYUV.eotfTable`, `eotfTableSize` floats, in the `constant` address space). The result is identical, code for
/// code, to the T-235 two-pass kernels (`LegacyTwoPassKernel` in XCTest keeps their source as the reference).
/// The source texture is `bgra8Unorm` holding sRGB-encoded values (not `_srgb`: no conversion on read).
/// Compile with safe math (`MTLCompileOptions.mathMode = .safe`) so division and rounding stay close to the CPU.
public enum SharpYUVKernel {
    public static let fusedFunction = "sharp_fused"

    /// `sharp_luma`'s `mode` buffer value: nil upsampling = plain Y'.
    public static func lumaMode(_ adjustFor: SharpYUV.Upsample?) -> UInt32 {
        switch adjustFor {
        case nil: return 0
        case .nearest?: return 1
        }
    }

    public static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float KR = 0.2126f, KG = 0.7152f, KB = 0.0722f;
    constant float CR_R = 1.5748f, CB_G = 0.187324f, CR_G = 0.468124f, CB_B = 1.8556f;
    constant int LUT_SIZE = \(SharpYUV.eotfTableSize);

    static inline float to_linear(float v, constant float *lut) {
        float c = clamp(v, 0.0f, 1.0f) * float(LUT_SIZE - 1);
        int i = min(int(c), LUT_SIZE - 2);
        float f = c - float(i);
        return lut[i] + f * (lut[i + 1] - lut[i]);
    }

    static inline float luminance(float3 p, constant float *lut) {
        return KR * to_linear(p.r, lut) + KG * to_linear(p.g, lut) + KB * to_linear(p.b, lut);
    }

    static inline float rebuilt(int y_code, float cb, float cr, constant float *lut) {
        float y = float(y_code) / 255.0f;
        float3 p = clamp(float3(y + CR_R * cr, y - CB_G * cb - CR_G * cr, y + CB_B * cb), 0.0f, 1.0f);
        return luminance(p, lut);
    }

    // Smallest code whose rebuilt luminance reaches `target` (255 when none does), found by galloping out from `g`
    // and bisecting the bracket. The luminance is monotonic in the code, so the result does not depend on `g` and
    // equals the CPU reference's plain bisection. `lc` = L(code), `lprev` = L(code - 1) (when code > 0).
    static inline int reach(float target, float cb, float cr, int g, constant float *lut,
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

    // Luma code of one pixel `c` whose 2x2 block has chroma codes `a` (Cb, Cr).
    static inline int luma_code(float3 c, float2 a, uint mode, constant float *lut) {
        int y0 = int(clamp(floor((KR * c.r + KG * c.g + KB * c.b) * 255.0f + 0.5f), 0.0f, 255.0f));
        if (mode == 0) { return y0; }
        // Flat: the decoder sees this pixel's own chroma; keep the plain code (skips the search).
        float yp = KR * c.r + KG * c.g + KB * c.b;
        float2 own = clamp(floor(float2((c.b - yp) / CB_B, (c.r - yp) / CR_R) * 255.0f + 128.0f + 0.5f),
                           0.0f, 255.0f);
        if (all(own == a)) { return y0; }
        float cb = (a.x - 128.0f) / 255.0f, cr = (a.y - 128.0f) / 255.0f;
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
        return code;
    }

    kernel void sharp_fused(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> cbcr [[texture(1)]],
                            texture2d<float, access::write> luma [[texture(2)]],
                            constant uint &mode [[buffer(0)]],
                            constant float *lut [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= cbcr.get_width() || gid.y >= cbcr.get_height()) return;
        uint w = src.get_width(), h = src.get_height();
        float3 px[4];
        float cb = 0.0f, cr = 0.0f;
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 p = uint2(min(2 * gid.x + dx, w - 1), min(2 * gid.y + dy, h - 1));
                float3 c = src.read(p).rgb;
                px[dy * 2 + dx] = c;
                float yp = KR * c.r + KG * c.g + KB * c.b;
                cb += (c.b - yp) / CB_B;
                cr += (c.r - yp) / CR_R;
            }
        }
        float2 code = clamp(floor(float2(cb, cr) * 0.25f * 255.0f + 128.0f + 0.5f), 0.0f, 255.0f);
        cbcr.write(float4(code / 255.0f, 0.0f, 0.0f), gid);
        for (uint dy = 0; dy < 2; dy++) {
            for (uint dx = 0; dx < 2; dx++) {
                uint2 p = uint2(2 * gid.x + dx, 2 * gid.y + dy);
                // Past the edge of an odd-sized frame: the block's repeated pixel has no luma sample.
                if (p.x >= w || p.y >= h) continue;
                int y = luma_code(px[dy * 2 + dx], code, mode, lut);
                luma.write(float4(float(y) / 255.0f, 0.0f, 0.0f, 0.0f), p);
            }
        }
    }
    """
}
