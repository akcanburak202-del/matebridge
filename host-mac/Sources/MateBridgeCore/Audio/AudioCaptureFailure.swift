/// Reasons a capture backend reports in `AudioCaptureEvent.failed` (short tokens, logged as `reason=`), and which of
/// them are worth retrying shortly (T-119).
///
/// Transient: creating the process tap or the private aggregate device. Right after the previous capture was torn
/// down (a session takeover stops one stream and starts the next within milliseconds), Core Audio has been seen to
/// return `noErr` from `AudioHardwareCreateProcessTap` without a tap object: the daemon is presumably still removing
/// the old tap and aggregate. A short, growing delay lets it finish.
///
/// Everything else is permanent for this request: no output device, an unsupported tap format or buffer layout, the
/// IOProc refused (permission), the device refusing to start, or the setup changing under the permission prompt.
public enum AudioCaptureFailure {
    public static let noOutputDevice = "no_output_device"
    public static let noOutputUID = "no_output_uid"
    public static let tapCreate = "tap_create"
    public static let tapFormat = "tap_format"
    public static let tapLayout = "tap_layout"
    public static let aggregateCreate = "aggregate_create"
    public static let ioprocCreate = "ioproc_create"
    public static let deviceStart = "device_start"

    /// `tap_format_<rate>hz_<channels>ch`: the tap delivers a format we do not convert.
    public static func unsupportedFormat(sampleRate: Int, channels: UInt32) -> String {
        "\(tapFormat)_\(sampleRate)hz_\(channels)ch"
    }

    /// `setup_changed_<what>`: the setup kept changing while the permission prompt was open.
    public static func setupChanged(_ change: String) -> String {
        "setup_changed_\(change)"
    }

    /// True for a failure that a later attempt of the same request may not hit.
    public static func isTransient(_ reason: String) -> Bool {
        reason == tapCreate || reason == aggregateCreate
    }
}
