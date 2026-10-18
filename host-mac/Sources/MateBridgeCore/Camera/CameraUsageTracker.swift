// "Does a Mac app use the virtual camera?" (decision 0040, T-354 experiment 2026-10-18).
//
// Measured with `tools/obs-cam-probe --watch --pattern`: the OBS device's `DeviceIsRunningSomewhere` (and `IsRunning`)
// go to 1 the moment our own process starts the sink stream, and back to 0 when it stops. So the raw property says
// "someone uses the camera" only while we are not writing. While we write, it cannot tell our own writing from an
// app's reading.
//
// The tracker therefore works in two regimes:
// - Not writing: usage is the raw property.
// - Writing: usage is assumed to continue. The host asks for a probe (`startProbe`) only when it makes sense (the Mac
//   was idle for a long time, or goes to sleep; `CameraIdleAudit`): the sink is paused (the host stops the sink stream)
//   and the raw property is read. It falling to 0 ends the probe at once; still 1 after `settleUs` means another
//   client runs, resume writing. 0 means the app is gone, the sink stays stopped and the usage ends.
//
// A manual override (menu item) holds usage on and disables the probes: the fallback if the probe cannot be used.
// Pure and clock-free; the host feeds the raw property and the sink state and performs the returned actions.

public struct CameraUsageTracker: Sendable {
    public enum Action: Equatable, Sendable {
        /// Stop the sink stream now (`CMIODeviceStopStream`); the settle period starts.
        case pauseSink
        /// Start the sink stream again.
        case resumeSink
    }

    public struct Configuration: Sendable {
        /// Sink stopped at most this long before the raw property is read as "still used". The property falling ends the
        /// wait early (it fell within ~5 ms in the T-354 loopback test; 0.6 s was the first, cautious value).
        public var settleUs: UInt64 = 500_000
        public init() {}
    }

    private enum Phase: Equatable {
        case normal
        /// The sink was paused by a probe; the raw property is read at the deadline.
        case probing(deadline: UInt64)
        /// The probe found no other client: the sink stays stopped until the raw property rises again.
        case parked
    }

    public var configuration: Configuration

    private var raw = false
    private var writing = false
    private var manual = false
    private var phase = Phase.normal

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// Whether an app uses the virtual camera, as far as can be told.
    public var inUse: Bool {
        if manual { return true }
        switch phase {
        case .probing: return true  // undecided until the deadline: the earlier answer stands
        case .parked: return raw
        case .normal: return writing ? true : raw
        }
    }

    /// Whether a probe could start now: writing, not manual, no probe running or parked.
    public var canProbe: Bool { writing && !manual && phase == .normal }
    public var isManual: Bool { manual }
    public var isProbing: Bool { if case .probing = phase { true } else { false } }
    public var isParked: Bool { phase == .parked }

    /// Earliest instant a `tick` has something to do; nil when nothing is pending.
    public var nextDeadline: UInt64? {
        switch phase {
        case .probing(let deadline): return deadline
        case .parked: return nil
        case .normal: return nil
        }
    }

    /// The raw `DeviceIsRunningSomewhere` changed (or was read).
    public mutating func running(_ value: Bool, now: UInt64) -> [Action] {
        raw = value
        if phase == .parked, value {  // an app is back before the filter ended: write again
            phase = .normal
            return writing ? [.resumeSink] : []
        }
        if case .probing = phase, !value {  // it fell because we stopped: nobody else reads
            phase = .parked
        }
        return []
    }

    /// The host started (true) or stopped (false) writing frames to the sink for the running camera stream.
    public mutating func sinkWriting(_ value: Bool, now: UInt64) -> [Action] {
        guard writing != value else { return [] }
        writing = value
        phase = .normal
        return []
    }

    /// Pause the sink and read the property after the settle time (or when it falls). Nothing when not writing, manual,
    /// or a probe is already under way.
    public mutating func startProbe(now: UInt64) -> [Action] {
        guard canProbe else { return [] }
        phase = .probing(deadline: now + configuration.settleUs)
        return [.pauseSink]
    }

    /// The manual "camera is in use" override. Turning it on while parked resumes the sink.
    public mutating func setManual(_ on: Bool, now: UInt64) -> [Action] {
        guard manual != on else { return [] }
        manual = on
        if on {
            if phase == .parked, writing {
                phase = .normal
                return [.resumeSink]
            }
            if case .probing = phase {
                phase = .normal
                return [.resumeSink]
            }
        }
        return []
    }

    public mutating func tick(now: UInt64) -> [Action] {
        guard case .probing(let deadline) = phase, now >= deadline else { return [] }
        if raw {
            phase = .normal
            return [.resumeSink]
        }
        phase = .parked
        return []
    }
}
