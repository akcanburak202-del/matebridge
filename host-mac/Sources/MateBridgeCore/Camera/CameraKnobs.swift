/// Experiment settings of the tablet camera (docs/KNOBS.md). Defaults are the shipped behaviour.
public enum CameraKnobs {
    public static let idleVariable = "MATEBRIDGE_CAMERA_IDLE_S"
    public static let defaultIdleSeconds = 600.0
    public static let idleRange = 10.0...86_400.0

    /// `MATEBRIDGE_CAMERA_IDLE_S`: the Mac must have had no user input this long before the camera usage is checked
    /// while the camera is being written (the check pauses the picture for a moment), and the spacing of repeated checks
    /// while it stays idle. Not a number, or outside 10...86400, is the default (600).
    public static func idleUs(_ text: String?) -> UInt64 {
        var seconds = defaultIdleSeconds
        if let text, let value = Double(text.trimmingCharacters(in: .whitespaces)), idleRange.contains(value) {
            seconds = value
        }
        return UInt64(seconds * 1_000_000)
    }
}
