import Foundation
import MateBridgeCore

/// Keeps Huawei's panel at 120 Hz over USB (T-389, decision 0044, `MATEBRIDGE_HOLD120=1`): while the conditions of
/// `Hold120Conditions` hold, about once a second it runs `adb -s <serial> shell input touchscreen tap 2 2` (press and
/// release in one command; never a separate DOWN). A round is skipped while real touch, pen or pointer input arrived
/// in the last 1.5 s. The tablet client swallows the tap (T-390).
///
/// Threading: decisions come from the pure `Hold120Planner` on `queue`; the adb child process (hard 2 s deadline)
/// runs on `adbQueue`, one at a time, so a hung adb never blocks the decisions, the video path, the input path or the
/// main thread. The timer only exists while the hold is on and a tap is not running. The serial is never logged.
final class Hold120Controller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.matebridge.hold120", qos: .utility)
    private let adbQueue = DispatchQueue(label: "dev.matebridge.hold120.adb", qos: .utility)
    private let logger = SessionLogger(component: "usb")
    private let runner = ProcessRunner(environment: AdbBinary.environment)
    private let registry: UsbDeviceRegistry

    // Confined to `queue`.
    private var planner = Hold120Planner()
    private var conditions = Hold120Conditions.none
    private var timer: DispatchWorkItem?
    private var stopped = false
    private var adbPath: String?

    /// Clock time (`HostClock`) of the latest real input; 0 = none. Written from the session's delivery thread at up to
    /// the pen rate, so it is a lock-protected scalar and never hops to a queue.
    private let inputLock = NSLock()
    private var lastInputUs: UInt64 = 0

    init(registry: UsbDeviceRegistry = .shared) {
        self.registry = registry
        registry.setObserver { [weak self] in self?.queue.async { self?.reevaluate() } }
    }

    /// The session facts changed (any thread). Identical conditions are ignored. `deviceKnown` of `facts` is ignored
    /// (pass false): the controller takes it from the `UsbDeviceRegistry`.
    func update(sessionFacts facts: Hold120Conditions) {
        queue.async { [self] in
            guard !stopped, facts != conditions else { return }
            conditions = facts
            reevaluate()
        }
    }

    /// A touch, pen or pointer message arrived from the tablet (any thread, hot path).
    func noteInput() {
        let now = HostClock.nowUs()
        inputLock.withLock { lastInputUs = now }
    }

    func shutdown() {
        registry.setObserver(nil)
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: On `queue`

    /// Re-reads the registry, applies the planner and arms the next wake. Every wake and every event comes here.
    private func reevaluate() {
        guard !stopped else { return }
        timer?.cancel()
        timer = nil
        let serial = registry.serial
        var facts = conditions
        facts.deviceKnown = serial != nil  // owned here: the caller does not know the USB device
        // Input first, then the clock: an input stamped in between is newer than `now`, which the planner counts as recent.
        let input = inputLock.withLock { lastInputUs }
        let now = HostClock.nowUs()
        if let change = planner.evaluate(nowUs: now, conditions: facts) {
            logger.log(.info, "hold120", sessionID: 0, generation: 0, fields: change.logFields)
        }
        switch planner.next(nowUs: now, lastInputUs: input == 0 ? nil : input) {
        case .off, .waitForCompletion:
            break
        case .sleep(let untilUs):
            arm(afterUs: untilUs > now ? untilUs - now : 0)
        case .tap:
            if let serial { startTap(serial: serial) } else { planner.tapFinished(nowUs: now, success: false) }
        }
        if let stats = planner.takeStats(nowUs: now) {
            logger.log(.info, "hold120_stats", sessionID: 0, generation: 0, fields: stats.logFields)
        }
    }

    private func arm(afterUs delay: UInt64) {
        let item = DispatchWorkItem { [weak self] in self?.reevaluate() }
        timer = item
        queue.asyncAfter(deadline: .now() + .microseconds(Int(min(delay, 60_000_000))), execute: item)
    }

    private func startTap(serial: String) {
        let cached = adbPath
        adbQueue.async { [self] in
            let ok = Self.tap(runner: runner, serial: serial, cachedAdb: cached)
            queue.async { [self] in
                if let path = ok.adb { adbPath = path } else { adbPath = nil }
                planner.tapFinished(nowUs: HostClock.nowUs(), success: ok.success)
                reevaluate()
            }
        }
    }

    /// Never starts an adb server: if none answers on loopback the tap fails (the watcher owns the server).
    private static func tap(runner: ProcessRunner, serial: String, cachedAdb: String?)
        -> (success: Bool, adb: String?) {
        guard let adb = cachedAdb ?? AdbBinary.locate(), AdbBinary.serverUp else { return (false, nil) }
        let result = runner.run(adb, ["-s", serial, "shell", "input", "touchscreen", "tap", "2", "2"],
                                timeout: Hold120Planner.tapTimeout)
        return (result.succeeded, result.succeeded ? adb : nil)
    }
}
