import Foundation

/// Where packed full colour (decision 0034, PROTOCOL.md 0x05 "Tam renk") applies. Pure.
public enum FullChromaPolicy {
    /// Günlük 60 only: 60 fps, the native HiDPI display (no 1x game display), scale 1000, SDR, HEVC, and a size the
    /// AVC444v2 layout can pack (`width % 4 == 0`, `height % 2 == 0`). Everything else uses sharp colour (0033).
    public static func qualifies(_ s: VideoSettings) -> Bool {
        s.fps == 60 && s.displayHiDPI && s.scalePermille == 1000 && s.dynamicRange == .sdr && s.codec == .hevc
            && AVC444v2.isValid(width: s.encodedWidthPx, height: s.encodedHeightPx)
    }
}
