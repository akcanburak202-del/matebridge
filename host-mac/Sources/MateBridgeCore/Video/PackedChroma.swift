import Foundation

/// The AVC444v2 sample layout (decision 0034; MS-RDPEGFX 3.3.8.3.3, FreeRDP `prim_YUV.c`; ported from the T-255 probe
/// `probes/yuv444-probe`), implemented by `PackedChromaKernel`. `width % 4 == 0`, `height % 2 == 0`.
/// The CPU reference (`pack`, `unpack`, `planes444`; the tests compare the kernel with it) is in the test target
/// (`PackedChromaReference.swift`).
///
/// Main view (an ordinary 4:2:0 picture): Y = Y444; Cb, Cr = the (even column, even row) chroma sample (`pick`).
/// Auxiliary view (a 4:2:0 picture carrying the other 3/4 of Cb and Cr):
/// - aux Y, left half (x < W/2): Cb444[2x + 1, y]; right half: Cr444[2(x - W/2) + 1, y] (all odd columns)
/// - aux Cb, left half (x < W/4): Cb444[4x, 2j + 1]; right half: Cr444[4(x - W/4), 2j + 1]
/// - aux Cr, left half: Cb444[4x + 2, 2j + 1]; right half: Cr444[4(x - W/4) + 2, 2j + 1]
public enum AVC444v2 {
    public static func isValid(width: Int, height: Int) -> Bool {
        width > 0 && height > 0 && width % 4 == 0 && height % 2 == 0
    }
}

/// Metal source of the packer (T-255 `pack_v2`, fused single pass, main chroma = `pick`). Compiled at run time with
/// safe math by the host's `PackedChromaPacker` and by XCTest (which compares it with `AVC444v2`).
///
/// The source is a `bgra8Unorm` texture holding sRGB-encoded values (no conversion on read). Grid `W/2 x H/2`, one
/// thread per 2x2 block; outputs `r8Unorm` Y and `rg8Unorm` CbCr textures for the main and the auxiliary picture.
public enum PackedChromaKernel {
    public static let function = "pack_v2"

    public static let metalSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float KR = 0.2126f, KG = 0.7152f, KB = 0.0722f;
    constant float CR_DIV = 1.5748f, CB_DIV = 1.8556f;

    static inline float3 ycc(texture2d<float, access::read> src, uint2 p) {
        float3 c = src.read(p).rgb;
        float y = KR * c.r + KG * c.g + KB * c.b;
        float cb = (c.b - y) / CB_DIV;
        float cr = (c.r - y) / CR_DIV;
        return clamp(floor(float3(y, cb, cr) * 255.0f + float3(0.5f, 128.5f, 128.5f)), 0.0f, 255.0f);
    }

    static inline float unorm(float code) { return code / 255.0f; }

    kernel void pack_v2(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> mainY [[texture(1)]],
                        texture2d<float, access::write> mainC [[texture(2)]],
                        texture2d<float, access::write> auxY [[texture(3)]],
                        texture2d<float, access::write> auxC [[texture(4)]],
                        uint2 g [[thread_position_in_grid]]) {
        uint cw = src.get_width() / 2, q = src.get_width() / 4;
        if (g.x >= cw || g.y >= src.get_height() / 2) { return; }
        uint x0 = 2 * g.x, y0 = 2 * g.y;
        float3 a = ycc(src, uint2(x0, y0)), b = ycc(src, uint2(x0 + 1, y0));
        float3 c = ycc(src, uint2(x0, y0 + 1)), d = ycc(src, uint2(x0 + 1, y0 + 1));
        bool right = g.x >= q;
        uint sx = 4 * (right ? g.x - q : g.x);
        float3 p1 = ycc(src, uint2(sx, y0 + 1));
        float3 p2 = ycc(src, uint2(sx + 2, y0 + 1));
        mainY.write(float4(unorm(a.x)), uint2(x0, y0));
        mainY.write(float4(unorm(b.x)), uint2(x0 + 1, y0));
        mainY.write(float4(unorm(c.x)), uint2(x0, y0 + 1));
        mainY.write(float4(unorm(d.x)), uint2(x0 + 1, y0 + 1));
        mainC.write(float4(unorm(a.y), unorm(a.z), 0.0f, 1.0f), g);
        auxY.write(float4(unorm(b.y)), uint2(g.x, y0));
        auxY.write(float4(unorm(d.y)), uint2(g.x, y0 + 1));
        auxY.write(float4(unorm(b.z)), uint2(cw + g.x, y0));
        auxY.write(float4(unorm(d.z)), uint2(cw + g.x, y0 + 1));
        float2 ac = right ? float2(p1.z, p2.z) : float2(p1.y, p2.y);
        auxC.write(float4(unorm(ac.x), unorm(ac.y), 0.0f, 1.0f), g);
    }
    """
}
