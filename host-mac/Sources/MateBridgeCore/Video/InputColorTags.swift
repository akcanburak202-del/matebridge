import Foundation

/// Colour tags of a pixel buffer or of an encoder session (T-113): the raw CoreVideo string values of
/// `kCVImageBufferColorPrimariesKey`, `kCVImageBufferTransferFunctionKey` and `kCVImageBufferYCbCrMatrixKey`
/// (for example `ITU_R_709_2`, `IEC_sRGB`). nil = the tag is absent.
public struct ColorTags: Equatable, Sendable {
    public var primaries: String?
    public var transfer: String?
    public var matrix: String?

    public init(primaries: String? = nil, transfer: String? = nil, matrix: String? = nil) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
    }

    public var isEmpty: Bool { primaries == nil && transfer == nil && matrix == nil }

    /// Log value `primaries/transfer/matrix`, `-` for an absent tag.
    public var logValue: String { [primaries, transfer, matrix].map { $0 ?? "-" }.joined(separator: "/") }
}

/// Whether a captured buffer's colour tags must be rewritten to the encoder session's before encoding (T-113).
///
/// VideoToolbox converts every input buffer whose colour tags differ from the session's colour properties into the
/// session's colour space before the hardware encoder sees it. ScreenCaptureKit (configured for sRGB) tags its 4:2:0
/// buffers `ITU_R_709_2` / `ITU_R_709_2` / `ITU_R_709_2` and attaches an sRGB `CGColorSpace`, while the session
/// declares sRGB transfer (`STREAM_CONFIG` transfer 13). Measured on the M6 at 2800x1840 (NOTES 2026-10-02): that
/// conversion costs ~2.4 ms per frame and lifts luma by ~8 levels on average (a gamma change applied to pixels that
/// SCK already encoded for sRGB). Rewriting the buffer tags to the session's skips it: encoded bytes are then the
/// captured pixels.
///
/// A buffer with no colour information at all is left alone (VideoToolbox does not convert it). One that carries
/// only some tags, or only a `CGColorSpace`, is converted by VideoToolbox (measured), so it is rewritten too.
///
/// The rewrite is unconditional since T-204 (decision 0026 retired its A/B switch).
public enum InputRetag {
    /// True when the buffer carries colour information (`buffer` tags or a `CGColorSpace` attachment) that differs
    /// from the session's tags.
    public static func needsRetag(buffer: ColorTags, hasColorSpace: Bool, session: ColorTags) -> Bool {
        guard !buffer.isEmpty || hasColorSpace else { return false }
        return buffer != session
    }
}
