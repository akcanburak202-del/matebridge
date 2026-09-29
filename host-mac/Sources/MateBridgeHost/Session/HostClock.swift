import CoreMedia

/// The one host clock: `CMClockGetHostTimeClock` (mach absolute time), in microseconds.
/// `VIDEO_FRAME.capture_time_us` (ScreenCaptureKit timestamps) and PING/PONG `responder_time_us` must both come
/// from this clock so the client's clock-offset estimate (PROTOCOL.md section 6) applies to capture times.
enum HostClock {
    static func nowUs() -> UInt64 {
        UInt64(max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))) * 1_000_000)
    }
}
