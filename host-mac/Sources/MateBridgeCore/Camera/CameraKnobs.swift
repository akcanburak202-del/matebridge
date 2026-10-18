/// Experiment settings of the tablet camera (docs/KNOBS.md). Defaults are the shipped behaviour.
public enum CameraKnobs {
    public static let probeIntervalVariable = "MATEBRIDGE_CAMERA_PROBE_S"
    public static let defaultProbeIntervalSeconds = 15.0
    public static let probeIntervalRange = 3.0...300.0

    /// `MATEBRIDGE_CAMERA_PROBE_S`: seconds between two usage probes while the camera is being written (the sink stream
    /// pauses for a moment each time). Not a number, or outside 3...300, is the default (15).
    public static func probeIntervalUs(_ text: String?) -> UInt64 {
        var seconds = defaultProbeIntervalSeconds
        if let text, let value = Double(text.trimmingCharacters(in: .whitespaces)), probeIntervalRange.contains(value) {
            seconds = value
        }
        return UInt64(seconds * 1_000_000)
    }
}
