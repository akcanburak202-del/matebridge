import Foundation

/// The T-235 chroma pass (sRGB-encoded `BGRA` -> full-range BT.709 8-bit 4:2:0, with a per-pixel luma adjustment, "sharp
/// YUV"; Ström, Samuelsson, Dovstam, "Luma Adjustment for High Dynamic Range Video", DCC 2016; libwebp `sharpyuv`).
/// Research `docs/research/2026-10-05-yuv444.md` §3b. The pass itself is the Metal kernel (`SharpYUVKernel`); this file
/// holds what it shares with the host: the assumed decoder upsampling and the sRGB EOTF table.
///
/// The CPU reference of the pass (plain and luma-adjusted conversion, decoder model, PSNR metric) lives in the test
/// target (`SharpYUVReference.swift`); XCTest compares the kernel with it (within one code value: `pow` and rounding
/// ties may differ on the GPU).
public enum SharpYUV {
    /// The chroma upsampling the decoder/display is assumed to use.
    public enum Upsample: String, Equatable, Sendable, CaseIterable {
        case nearest
    }

    /// The sRGB EOTF (encoded 0...1 to linear).
    public static func srgbToLinear(_ v: Float) -> Float {
        let c = clamp01(v)
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    /// Points of the EOTF table the pass interpolates (the kernel reads the same table from a buffer: `pow` per
    /// evaluation cost ~16 ms per 2800x1840 frame on the M6 GPU, the table ~1/10 of that).
    public static let eotfTableSize = 1024
    /// `srgbToLinear` at `i / (eotfTableSize - 1)`.
    public static let eotfTable: [Float] = (0..<eotfTableSize).map { srgbToLinear(Float($0) / Float(eotfTableSize - 1)) }

    static func clamp01(_ v: Float) -> Float { min(max(v, 0), 1) }
}
