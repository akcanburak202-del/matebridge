import Foundation

/// Full-resolution 8-bit planes (4:4:4), row-major, no padding.
public struct Planes444: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]

    public init(width: Int, height: Int) {
        let n = width * height
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: n)
        cb = y
        cr = y
    }
}

/// An 8-bit 4:2:0 picture with separate Cb and Cr planes (`width / 2 x height / 2` each).
public struct Planes420: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        y = [UInt8](repeating: 0, count: width * height)
        cb = [UInt8](repeating: 0, count: (width / 2) * (height / 2))
        cr = cb
    }
}

/// The AVC444v2 sample layout (decision 0034; MS-RDPEGFX 3.3.8.3.3, FreeRDP `prim_YUV.c`; ported from the T-255 probe
/// `probes/yuv444-probe`), CPU reference of `PackedChromaKernel`. `width % 4 == 0`, `height % 2 == 0`.
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

    public static func pack(_ p: Planes444) -> (main: Planes420, aux: Planes420) {
        let w = p.width, h = p.height
        precondition(isValid(width: w, height: h), "AVC444v2 needs width % 4 == 0 and height % 2 == 0")
        let cw = w / 2, ch = h / 2, q = w / 4
        var main = Planes420(width: w, height: h)
        var aux = Planes420(width: w, height: h)
        main.y = p.y
        for j in 0..<ch {
            for i in 0..<cw {
                main.cb[j * cw + i] = p.cb[2 * j * w + 2 * i]
                main.cr[j * cw + i] = p.cr[2 * j * w + 2 * i]
            }
        }
        for y in 0..<h {
            for x in 0..<cw {
                aux.y[y * w + x] = p.cb[y * w + 2 * x + 1]
                aux.y[y * w + cw + x] = p.cr[y * w + 2 * x + 1]
            }
        }
        for j in 0..<ch {
            let row = (2 * j + 1) * w
            for x in 0..<q {
                aux.cb[j * cw + x] = p.cb[row + 4 * x]
                aux.cr[j * cw + x] = p.cb[row + 4 * x + 2]
                aux.cb[j * cw + q + x] = p.cr[row + 4 * x]
                aux.cr[j * cw + q + x] = p.cr[row + 4 * x + 2]
            }
        }
        return (main, aux)
    }

    public static func unpack(main: Planes420, aux: Planes420) -> Planes444 {
        let w = main.width, h = main.height
        precondition(aux.width == w && aux.height == h && isValid(width: w, height: h))
        let cw = w / 2, ch = h / 2, q = w / 4
        var out = Planes444(width: w, height: h)
        out.y = main.y
        for y in 0..<h {
            for x in 0..<cw {
                out.cb[y * w + 2 * x + 1] = aux.y[y * w + x]
                out.cr[y * w + 2 * x + 1] = aux.y[y * w + cw + x]
            }
        }
        for j in 0..<ch {
            let row = (2 * j + 1) * w
            for x in 0..<q {
                out.cb[row + 4 * x] = aux.cb[j * cw + x]
                out.cb[row + 4 * x + 2] = aux.cr[j * cw + x]
                out.cr[row + 4 * x] = aux.cb[j * cw + q + x]
                out.cr[row + 4 * x + 2] = aux.cr[j * cw + q + x]
            }
        }
        for j in 0..<ch {
            for i in 0..<cw {
                out.cb[2 * j * w + 2 * i] = main.cb[j * cw + i]
                out.cr[2 * j * w + 2 * i] = main.cr[j * cw + i]
            }
        }
        return out
    }

    /// BT.709 full-range Y'CbCr codes of sRGB-encoded `bgra` (`stride` bytes per row), the maths of the kernel:
    /// Y = floor(255 Y' + 0.5), C = floor(255 C' + 128.5), clamped. Float arithmetic like the GPU (safe math).
    public static func planes444(bgra: [UInt8], width: Int, height: Int, stride: Int) -> Planes444 {
        var out = Planes444(width: width, height: height)
        let kr: Float = 0.2126, kg: Float = 0.7152, kb: Float = 0.0722
        func code(_ v: Float, _ bias: Float) -> UInt8 { UInt8(min(max((255 * v + bias).rounded(.down), 0), 255)) }
        for y in 0..<height {
            for x in 0..<width {
                let o = y * stride + x * 4
                let b = Float(bgra[o]) / 255, g = Float(bgra[o + 1]) / 255, r = Float(bgra[o + 2]) / 255
                let yp = kr * r + kg * g + kb * b
                let i = y * width + x
                out.y[i] = code(yp, 0.5)
                out.cb[i] = code((b - yp) / 1.8556, 128.5)
                out.cr[i] = code((r - yp) / 1.5748, 128.5)
            }
        }
        return out
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
