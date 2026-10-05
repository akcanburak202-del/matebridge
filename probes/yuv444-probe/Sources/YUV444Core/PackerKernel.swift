import Foundation

/// Metal source of the AVC444v2 packer (`AVC444v2` is its CPU reference; keep the two in step). Compiled at run time
/// (no resource bundle), with safe math, by `Packer444`.
///
/// The source is a `bgra8Unorm` texture holding sRGB-encoded values (no conversion on read). Colour codes are the
/// `ColorMath` ones, computed per sample as floats holding integers, so the mean in `box` mode is exact.
///
/// Kernels (grid = `W/2 x H/2`, one thread per 2x2 block, `W % 4 == 0`):
/// - `pack_v2`: fused pass, BGRA -> main Y, main CbCr and (when `withAux != 0`) aux Y, aux CbCr. `mode` 0 = pick,
///   1 = 2x2 box mean for the main chroma.
/// - `convert444` (grid `W x H`): BGRA -> three `r8Unorm` full-resolution planes (the first half of the two-pass variant,
///   and the 4:4:4 source readback of the tools).
/// - `pack_v2_planes` (grid `W/2 x H/2`): the second half, the same packing from those planes.
public enum PackerKernel {
    public static let fused = "pack_v2"
    public static let convert = "convert444"
    public static let fromPlanes = "pack_v2_planes"

    public static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float KR = 0.2126f, KG = 0.7152f, KB = 0.0722f;
    constant float CR_DIV = 1.5748f, CB_DIV = 1.8556f;

    // (Y, Cb, Cr) codes 0...255 of the pixel at p, as floats holding integers.
    static inline float3 ycc(texture2d<float, access::read> src, uint2 p) {
        float3 c = src.read(p).rgb;
        float y = KR * c.r + KG * c.g + KB * c.b;
        float cb = (c.b - y) / CB_DIV;
        float cr = (c.r - y) / CR_DIV;
        return clamp(floor(float3(y, cb, cr) * 255.0f + float3(0.5f, 128.5f, 128.5f)), 0.0f, 255.0f);
    }

    static inline float3 plane_ycc(texture2d<float, access::read> yT, texture2d<float, access::read> cbT,
                                   texture2d<float, access::read> crT, uint2 p) {
        return floor(float3(yT.read(p).r, cbT.read(p).r, crT.read(p).r) * 255.0f + 0.5f);
    }

    static inline float unorm(float code) { return code / 255.0f; }

    // One 2x2 block (i, j) of the output; `a b c d` are the block's (Y, Cb, Cr) in reading order, `p1`/`p2` the two aux
    // chroma source samples (cb, cr of the pixel at (4i, 2j+1) or (4(i-W/4), ...), and +2).
    static inline void write_block(uint2 g, uint cw, uint mode, uint withAux,
                                   float3 a, float3 b, float3 c, float3 d, float3 p1, float3 p2, bool right,
                                   texture2d<float, access::write> mainY, texture2d<float, access::write> mainC,
                                   texture2d<float, access::write> auxY, texture2d<float, access::write> auxC) {
        uint x0 = 2 * g.x, y0 = 2 * g.y;
        mainY.write(float4(unorm(a.x)), uint2(x0, y0));
        mainY.write(float4(unorm(b.x)), uint2(x0 + 1, y0));
        mainY.write(float4(unorm(c.x)), uint2(x0, y0 + 1));
        mainY.write(float4(unorm(d.x)), uint2(x0 + 1, y0 + 1));
        float2 mc = (mode == 0) ? a.yz : floor((a.yz + b.yz + c.yz + d.yz + 2.0f) * 0.25f);
        mainC.write(float4(unorm(mc.x), unorm(mc.y), 0.0f, 1.0f), g);
        if (withAux == 0) { return; }
        // Aux luma: odd columns of Cb (left half) and Cr (right half), every row.
        auxY.write(float4(unorm(b.y)), uint2(g.x, y0));
        auxY.write(float4(unorm(d.y)), uint2(g.x, y0 + 1));
        auxY.write(float4(unorm(b.z)), uint2(cw + g.x, y0));
        auxY.write(float4(unorm(d.z)), uint2(cw + g.x, y0 + 1));
        // Aux chroma: even columns, odd rows; left half takes Cb, right half Cr; Cb plane = x % 4 == 0, Cr plane = 2.
        float2 ac = right ? float2(p1.z, p2.z) : float2(p1.y, p2.y);
        auxC.write(float4(unorm(ac.x), unorm(ac.y), 0.0f, 1.0f), g);
    }

    kernel void pack_v2(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> mainY [[texture(1)]],
                        texture2d<float, access::write> mainC [[texture(2)]],
                        texture2d<float, access::write> auxY [[texture(3)]],
                        texture2d<float, access::write> auxC [[texture(4)]],
                        constant uint &mode [[buffer(0)]],
                        constant uint &withAux [[buffer(1)]],
                        uint2 g [[thread_position_in_grid]]) {
        uint cw = src.get_width() / 2, q = src.get_width() / 4;
        if (g.x >= cw || g.y >= src.get_height() / 2) { return; }
        uint x0 = 2 * g.x, y0 = 2 * g.y;
        float3 a = ycc(src, uint2(x0, y0)), b = ycc(src, uint2(x0 + 1, y0));
        float3 c = ycc(src, uint2(x0, y0 + 1)), d = ycc(src, uint2(x0 + 1, y0 + 1));
        bool right = g.x >= q;
        uint sx = 4 * (right ? g.x - q : g.x);
        float3 p1 = float3(0.0f), p2 = float3(0.0f);
        if (withAux != 0) {
            p1 = ycc(src, uint2(sx, y0 + 1));
            p2 = ycc(src, uint2(sx + 2, y0 + 1));
        }
        write_block(g, cw, mode, withAux, a, b, c, d, p1, p2, right, mainY, mainC, auxY, auxC);
    }

    kernel void convert444(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> yT [[texture(1)]],
                           texture2d<float, access::write> cbT [[texture(2)]],
                           texture2d<float, access::write> crT [[texture(3)]],
                           uint2 g [[thread_position_in_grid]]) {
        if (g.x >= src.get_width() || g.y >= src.get_height()) { return; }
        float3 v = ycc(src, g);
        yT.write(float4(unorm(v.x)), g);
        cbT.write(float4(unorm(v.y)), g);
        crT.write(float4(unorm(v.z)), g);
    }

    kernel void pack_v2_planes(texture2d<float, access::read> yT [[texture(0)]],
                               texture2d<float, access::read> cbT [[texture(1)]],
                               texture2d<float, access::read> crT [[texture(2)]],
                               texture2d<float, access::write> mainY [[texture(3)]],
                               texture2d<float, access::write> mainC [[texture(4)]],
                               texture2d<float, access::write> auxY [[texture(5)]],
                               texture2d<float, access::write> auxC [[texture(6)]],
                               constant uint &mode [[buffer(0)]],
                               constant uint &withAux [[buffer(1)]],
                               uint2 g [[thread_position_in_grid]]) {
        uint cw = yT.get_width() / 2, q = yT.get_width() / 4;
        if (g.x >= cw || g.y >= yT.get_height() / 2) { return; }
        uint x0 = 2 * g.x, y0 = 2 * g.y;
        float3 a = plane_ycc(yT, cbT, crT, uint2(x0, y0)), b = plane_ycc(yT, cbT, crT, uint2(x0 + 1, y0));
        float3 c = plane_ycc(yT, cbT, crT, uint2(x0, y0 + 1)), d = plane_ycc(yT, cbT, crT, uint2(x0 + 1, y0 + 1));
        bool right = g.x >= q;
        uint sx = 4 * (right ? g.x - q : g.x);
        float3 p1 = float3(0.0f), p2 = float3(0.0f);
        if (withAux != 0) {
            p1 = plane_ycc(yT, cbT, crT, uint2(sx, y0 + 1));
            p2 = plane_ycc(yT, cbT, crT, uint2(sx + 2, y0 + 1));
        }
        write_block(g, cw, mode, withAux, a, b, c, d, p1, p2, right, mainY, mainC, auxY, auxC);
    }
    """
}
