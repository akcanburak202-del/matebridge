/// System power transitions the host reacts to (T-128), from `IORegisterForSystemPower` messages.
public enum PowerEvent: String, Sendable, Equatable {
    /// `kIOMessageCanSystemSleep`: idle sleep is about to start (the host always allows it at once).
    case canSleep = "can_sleep"
    /// `kIOMessageSystemWillSleep`: the system is going to sleep (also `pmset sleepnow`, Apple menu > Sleep).
    case willSleep = "will_sleep"
    /// `kIOMessageSystemWillNotSleep`: an idle sleep that was asked about was cancelled.
    case willNotSleep = "will_not_sleep"
    /// `kIOMessageSystemHasPoweredOn`: the system is awake again.
    case didWake = "did_wake"

    /// `iokit_common_msg(n)` = `sys_iokit | sub_iokit_common | n` = `0xE0000000 | n` (IOKit/IOMessage.h). The macros
    /// are not imported into Swift, so the values are spelled out here.
    public static let canSystemSleepMessage: UInt32 = 0xE000_0270
    public static let systemWillSleepMessage: UInt32 = 0xE000_0280
    public static let systemWillNotSleepMessage: UInt32 = 0xE000_0290
    public static let systemHasPoweredOnMessage: UInt32 = 0xE000_0300

    /// The power event of an IOKit root-domain message; nil for every other message (e.g. `SystemWillPowerOn`).
    public static func fromIOKitMessage(_ message: UInt32) -> PowerEvent? {
        switch message {
        case canSystemSleepMessage: return .canSleep
        case systemWillSleepMessage: return .willSleep
        case systemWillNotSleepMessage: return .willNotSleep
        case systemHasPoweredOnMessage: return .didWake
        default: return nil
        }
    }

    /// Whether the system is (about to be) asleep after this event.
    public var isSleeping: Bool { self == .canSleep || self == .willSleep }

    /// `IOAllowPowerChange` must answer this message (otherwise sleep is delayed by up to 30 s).
    public var needsAcknowledgement: Bool { isSleeping }
}

/// Keeps the T-081 display wake from cancelling a deliberate system sleep (T-128). Pure; the coordinator asks it
/// before the `DisplayWakePolicy` rate limit.
///
/// Measured (NOTES 2026-10-02 ~13:45): on `pmset sleepnow` the displays go dark and SCStream fails with -3815 before
/// (or around) the sleep notification; waking the displays at that point cancelled the sleep. So:
/// - while the system is going to sleep (between `can_sleep`/`will_sleep` and `will_not_sleep`/`did_wake`) no wake
///   happens; the first refused wake of such an episode is logged (`wake_display_suppressed`);
/// - `capture_source_lost` (the first symptom) waits `captureLossDeferUs` before waking; a sleep notification in that
///   window drops it. A further loss while one is pending joins it (it never wakes earlier);
/// - `display_create_nil` while awake and with nothing pending wakes at once, as in T-081.
public struct SleepWakeGate: Sendable {
    public enum Request: Equatable, Sendable {
        /// Wake now (subject to the T-081 rate limit).
        case wakeNow
        /// Do not wake yet: ask `due(now:)` at `deadlineUs`.
        case deferred(deadlineUs: UInt64)
        /// A deferred wake is already pending; nothing new to schedule.
        case pending
        /// The system is going to sleep: no wake. `log` is true for the first refusal of this sleep episode.
        case suppressed(log: Bool)
    }

    public struct PowerOutcome: Equatable, Sendable {
        /// The state differs from the last one reported: write `ev=power state=…`.
        public var logState: Bool
        /// A pending deferred wake was dropped by this event and the episode had not logged a suppression yet:
        /// write `ev=wake_display_suppressed` (with this display-loss reason).
        public var suppressedPending: DisplayWakeReason?
    }

    /// How long a `capture_source_lost` waits for a sleep notification before waking the displays.
    public static let captureLossDeferUs: UInt64 = 1_500_000

    public let deferUs: UInt64
    /// True from a sleep notification until the system is awake again (or the sleep was cancelled).
    public private(set) var sleeping = false
    private var lastReported: PowerEvent?
    private var suppressionLogged = false
    private var pendingReason: DisplayWakeReason?
    public private(set) var pendingDeadlineUs: UInt64?

    public init(deferUs: UInt64 = SleepWakeGate.captureLossDeferUs) {
        self.deferUs = deferUs
    }

    /// The reason a deferred wake is waiting for, if any.
    public var pending: DisplayWakeReason? { pendingReason }

    public mutating func power(_ event: PowerEvent, now: UInt64) -> PowerOutcome {
        let logState = lastReported != event
        lastReported = event
        var dropped: DisplayWakeReason?
        if event.isSleeping {
            sleeping = true
            if let reason = pendingReason {
                pendingReason = nil
                pendingDeadlineUs = nil
                if !suppressionLogged {
                    suppressionLogged = true
                    dropped = reason
                }
            }
        } else {
            sleeping = false
            suppressionLogged = false
        }
        return PowerOutcome(logState: logState, suppressedPending: dropped)
    }

    /// The display was lost for `reason` during an accepted session (the caller checks both).
    public mutating func request(_ reason: DisplayWakeReason, now: UInt64) -> Request {
        if sleeping {
            let log = !suppressionLogged
            suppressionLogged = true
            return .suppressed(log: log)
        }
        if pendingReason != nil { return .pending }
        switch reason {
        case .captureSourceLost:
            let deadline = now + deferUs
            pendingReason = reason
            pendingDeadlineUs = deadline
            return .deferred(deadlineUs: deadline)
        case .displayCreateNil:
            return .wakeNow
        }
    }

    /// The pending wake, once its deadline has passed and no sleep notification dropped it (then cleared).
    public mutating func due(now: UInt64) -> DisplayWakeReason? {
        guard let reason = pendingReason, let deadline = pendingDeadlineUs, now >= deadline, !sleeping else {
            return nil
        }
        pendingReason = nil
        pendingDeadlineUs = nil
        return reason
    }

    /// The display came back, or the session ended: nothing to wake for any more.
    public mutating func cancelPending() {
        pendingReason = nil
        pendingDeadlineUs = nil
    }
}
