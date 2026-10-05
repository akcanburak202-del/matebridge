import Foundation

/// Full-resolution 8-bit planes (4:4:4), one array per component, row-major, no padding.
public struct Planes444: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]

    public init(width: Int, height: Int, y: [UInt8], cb: [UInt8], cr: [UInt8]) {
        precondition(y.count == width * height && cb.count == y.count && cr.count == y.count)
        self.width = width
        self.height = height
        self.y = y
        self.cb = cb
        self.cr = cr
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        let n = width * height
        self.init(width: width, height: height, y: [UInt8](repeating: fill, count: n),
                  cb: [UInt8](repeating: fill, count: n), cr: [UInt8](repeating: fill, count: n))
    }
}

/// An 8-bit 4:2:0 picture with separate Cb and Cr planes (`width / 2 x height / 2` each).
public struct Planes420: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var y: [UInt8]
    public var cb: [UInt8]
    public var cr: [UInt8]

    public var chromaWidth: Int { width / 2 }
    public var chromaHeight: Int { height / 2 }

    public init(width: Int, height: Int, y: [UInt8], cb: [UInt8], cr: [UInt8]) {
        precondition(y.count == width * height && cb.count == (width / 2) * (height / 2) && cr.count == cb.count)
        self.width = width
        self.height = height
        self.y = y
        self.cb = cb
        self.cr = cr
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        let c = (width / 2) * (height / 2)
        self.init(width: width, height: height, y: [UInt8](repeating: fill, count: width * height),
                  cb: [UInt8](repeating: fill, count: c), cr: [UInt8](repeating: fill, count: c))
    }
}

/// How the main view's chroma is derived from the 2x2 block of 4:4:4 chroma samples.
public enum MainChroma: String, Sendable, CaseIterable {
    /// The (even column, even row) sample: the main view is a plain 4:2:0 picture with top-left chroma siting, and the
    /// 4:4:4 reconstruction is exact (no filter to undo).
    case pick
    /// The rounded 2x2 mean (what FreeRDP's AVC444v2 encoder does): the main view is the better standalone 4:2:0
    /// picture (centred siting, no aliasing), but the (even, even) sample can only be estimated back.
    case box
}

/// How the decoder side rebuilds the (even column, even row) chroma sample.
public enum MainReconstruction: String, Sendable, CaseIterable {
    /// Use the main view's chroma as is (exact for `pick`; for `box` it is the 2x2 mean, i.e. slightly blurred).
    case asIs
    /// `box` only: solve the mean for the unknown sample, `4 * mean - the other three` (the other three are in the
    /// auxiliary view). Exact up to the mean's rounding (error -2...+1) before compression noise, which it amplifies.
    case inverseBox
}

/// The AVC444v2 sample layout [MS-RDPEGFX 3.3.8.3.3; FreeRDP `libfreerdp/primitives/prim_YUV.c`
/// `general_RGBToAVC444YUVv2` / `general_ChromaV2ToYUV444`], CPU reference. Sizes: `width % 4 == 0`, `height % 2 == 0`.
///
/// Main view (an ordinary 4:2:0 picture): Y = Y444; Cb, Cr = the (even column, even row) chroma, or its 2x2 mean.
/// Auxiliary view (also a 4:2:0 picture, carrying the other 3/4 of Cb and Cr):
/// - aux Y, left half (x < W/2):  Cb444[2x + 1, y]          (all odd columns, every row)
/// - aux Y, right half:           Cr444[2(x - W/2) + 1, y]
/// - aux Cb, left half (x < W/4): Cb444[4x, 2j + 1]         (even columns, odd rows; x % 4 == 0 ones)
/// - aux Cb, right half:          Cr444[4(x - W/4), 2j + 1]
/// - aux Cr, left half:           Cb444[4x + 2, 2j + 1]     (the x % 4 == 2 ones)
/// - aux Cr, right half:          Cr444[4(x - W/4) + 2, 2j + 1]
/// Every Cb/Cr sample is stored exactly once (box: the (even, even) one inside the mean).
public enum AVC444v2 {
    public static func isValid(width: Int, height: Int) -> Bool { width > 0 && height > 0 && width % 4 == 0 && height % 2 == 0 }

    public static func pack(_ p: Planes444, mainChroma: MainChroma) -> (main: Planes420, aux: Planes420) {
        let w = p.width, h = p.height
        precondition(isValid(width: w, height: h), "AVC444v2 needs width % 4 == 0 and height % 2 == 0")
        let cw = w / 2, ch = h / 2, q = w / 4
        var main = Planes420(width: w, height: h)
        var aux = Planes420(width: w, height: h)
        main.y = p.y
        for j in 0..<ch {
            for i in 0..<cw {
                let o = 2 * j * w + 2 * i
                switch mainChroma {
                case .pick:
                    main.cb[j * cw + i] = p.cb[o]
                    main.cr[j * cw + i] = p.cr[o]
                case .box:
                    main.cb[j * cw + i] = box(p.cb[o], p.cb[o + 1], p.cb[o + w], p.cb[o + w + 1])
                    main.cr[j * cw + i] = box(p.cr[o], p.cr[o + 1], p.cr[o + w], p.cr[o + w + 1])
                }
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

    public static func unpack(main: Planes420, aux: Planes420, reconstruction: MainReconstruction) -> Planes444 {
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
        // (even, even) samples: the other three samples of each 2x2 block are known by now.
        for j in 0..<ch {
            for i in 0..<cw {
                let o = 2 * j * w + 2 * i
                switch reconstruction {
                case .asIs:
                    out.cb[o] = main.cb[j * cw + i]
                    out.cr[o] = main.cr[j * cw + i]
                case .inverseBox:
                    out.cb[o] = unbox(main.cb[j * cw + i], out.cb[o + 1], out.cb[o + w], out.cb[o + w + 1])
                    out.cr[o] = unbox(main.cr[j * cw + i], out.cr[o + 1], out.cr[o + w], out.cr[o + w + 1])
                }
            }
        }
        return out
    }

    /// Rounded mean of four samples, `(a + b + c + d + 2) >> 2`.
    @inline(__always) public static func box(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 {
        UInt8((Int(a) + Int(b) + Int(c) + Int(d) + 2) >> 2)
    }

    /// The first sample of a block from its mean and the other three: `4 mean - b - c - d`, clamped.
    @inline(__always) public static func unbox(_ mean: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> UInt8 {
        UInt8(min(max(4 * Int(mean) - Int(b) - Int(c) - Int(d), 0), 255))
    }
}
