extension VideoSettings {
    /// Largest pixel edge the host accepts from a HELLO (guards against garbage values).
    public static let maxEdgePx = 4096
    public static let defaultFps = 60

    /// Settings for a connecting tablet: virtual display at the tablet's native pixel size, 2x HiDPI
    /// (points = pixels / 2), HEVC, `min(tablet max_refresh_hz, 60)` fps (60 if the tablet reports 0).
    /// A HELLO with an unusable size (zero, odd, or larger than `maxEdgePx`) falls back to `tabletDefault`.
    /// This size is the session's native size (`nativeWidthPx`/`nativeHeightPx`): a game display from `STREAM_PREFS`
    /// (decision 0029) replaces the display but keeps the native size for validation, the lease and the way back.
    public static func forTablet(_ hello: Hello) -> VideoSettings {
        let w = Int(hello.screenWidthPx)
        let h = Int(hello.screenHeightPx)
        var settings = VideoSettings.tabletDefault
        if w >= 2, h >= 2, w % 2 == 0, h % 2 == 0, w <= maxEdgePx, h <= maxEdgePx {
            settings.widthPx = w
            settings.heightPx = h
            settings.widthPt = w / 2
            settings.heightPt = h / 2
        }
        let hz = Int(hello.maxRefreshHz)
        settings.fps = hz > 0 ? min(hz, defaultFps) : defaultFps
        settings.clientFullChroma = hello.capabilities.contains(.fullChroma)
        return settings
    }
}
