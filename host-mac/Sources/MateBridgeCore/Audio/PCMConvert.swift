// Float32 -> PCM s16le conversion for the audio capture path (decision 0011, PROTOCOL.md 0x31 PCM_S16LE).
// Runs on the Core Audio real-time thread: no allocation, no locks, no logging.

/// Where the samples of one IOProc callback are. Pointers are only valid for that callback.
public enum PCMSource {
    /// One buffer, channels interleaved (L R L R ...).
    case interleaved(UnsafePointer<Float>)
    /// One buffer per channel.
    case planar(left: UnsafePointer<Float>, right: UnsafePointer<Float>)
}

public enum PCMConvert {
    /// `round(clamp(x, -1, 1) * 32767)`, half away from zero (PROTOCOL.md 1); NaN is silence. -1.0 maps to -32767.
    @inline(__always)
    public static func s16(_ x: Float) -> Int16 {
        guard !x.isNaN else { return 0 }
        let clamped = min(max(x, -1), 1)
        return Int16((clamped * 32767).rounded())
    }

    /// Converts `frames` stereo frames from `source`, starting at frame `offset`, into `dst` as s16le interleaved
    /// (4 bytes per frame). Returns the sum of squares of the clamped samples (for the level meter).
    @inline(__always)
    public static func convertStereo(_ source: PCMSource, offset: Int, frames: Int,
                                     into dst: UnsafeMutableRawPointer) -> Double {
        var sumSquares: Double = 0
        switch source {
        case .interleaved(let src):
            let base = src + offset * 2
            for i in 0..<(frames * 2) {
                let v = s16(base[i])
                dst.storeBytes(of: v.littleEndian, toByteOffset: i * 2, as: Int16.self)
                let f = Double(v) / 32767
                sumSquares += f * f
            }
        case .planar(let left, let right):
            let l = left + offset
            let r = right + offset
            for i in 0..<frames {
                let a = s16(l[i])
                let b = s16(r[i])
                dst.storeBytes(of: a.littleEndian, toByteOffset: i * 4, as: Int16.self)
                dst.storeBytes(of: b.littleEndian, toByteOffset: i * 4 + 2, as: Int16.self)
                let fa = Double(a) / 32767
                let fb = Double(b) / 32767
                sumSquares += fa * fa + fb * fb
            }
        }
        return sumSquares
    }
}
