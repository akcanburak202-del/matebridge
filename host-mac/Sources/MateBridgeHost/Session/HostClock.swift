import CoreMedia

/// The one host clock: `CMClockGetHostTimeClock` (mach absolute time), in microseconds.
/// `VIDEO_FRAME.capture_time_us` (ScreenCaptureKit timestamps), `AUDIO_FRAME.capture_time_us` (IOProc `mHostTime`)
/// and PING/PONG `responder_time_us` must all come from this clock so the client's clock-offset estimate
/// (PROTOCOL.md section 6) applies to capture times.
enum HostClock {
    static func nowUs() -> UInt64 {
        UInt64(max(0, CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))) * 1_000_000)
    }

    /// Mach host ticks (e.g. `AudioTimeStamp.mHostTime`) on the same clock, in microseconds. Linear, so it also
    /// converts tick durations.
    static func us(fromHostTicks ticks: UInt64) -> UInt64 {
        UInt64(max(0, CMTimeGetSeconds(CMClockMakeHostTimeFromSystemUnits(ticks))) * 1_000_000)
    }
}
