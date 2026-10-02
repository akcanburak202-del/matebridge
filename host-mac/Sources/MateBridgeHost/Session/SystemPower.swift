import Foundation
import IOKit
import IOKit.pwr_mgt
import MateBridgeCore

/// System sleep/wake notifications (T-128). Thin `IORegisterForSystemPower` wrapper; `SleepWakeGate` decides what
/// they mean. The handler runs on the observer's own serial queue and must return quickly: a sleep question is
/// answered (`IOAllowPowerChange`) right after it returns, so MateBridge never delays or vetoes sleep.
final class SystemPowerObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.matebridge.power")
    private let handler: @Sendable (PowerEvent) -> Void
    private let lock = NSLock()
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var started = false

    init(handler: @escaping @Sendable (PowerEvent) -> Void) {
        self.handler = handler
    }

    /// Registers for root-domain power messages. Returns false when IOKit refuses (then nothing is delivered).
    @discardableResult
    func start() -> Bool {
        lock.withLock {
            guard !started else { return true }
            // The registration holds one reference to the observer, released in `stop()`.
            let context = Unmanaged.passRetained(self)
            var port: IONotificationPortRef?
            var note: io_object_t = 0
            let root = IORegisterForSystemPower(context.toOpaque(), &port, Self.callback, &note)
            guard root != 0, let port else {
                context.release()
                return false
            }
            IONotificationPortSetDispatchQueue(port, queue)
            rootPort = root
            notifyPort = port
            notifier = note
            started = true
            return true
        }
    }

    /// Deregisters. Idempotent; no event is delivered once the queue has drained.
    func stop() {
        queue.sync {
            let wasStarted: Bool = lock.withLock {
                guard started else { return false }
                started = false
                IODeregisterForSystemPower(&notifier)
                IOServiceClose(rootPort)
                if let notifyPort { IONotificationPortDestroy(notifyPort) }
                notifyPort = nil
                rootPort = 0
                notifier = 0
                return true
            }
            if wasStarted { Unmanaged.passUnretained(self).release() }  // the registration's reference
        }
    }

    private func receive(_ messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        let (root, live) = lock.withLock { (rootPort, started) }
        guard live else { return }
        let event = PowerEvent.fromIOKitMessage(messageType)
        if let event { handler(event) }
        // Sleep questions are always allowed at once (no delay, no veto); the notification id is the argument.
        if messageType == PowerEvent.canSystemSleepMessage || messageType == PowerEvent.systemWillSleepMessage {
            IOAllowPowerChange(root, Int(bitPattern: argument))
        }
    }

    private static let callback: IOServiceInterestCallback = { refcon, _, messageType, argument in
        guard let refcon else { return }
        Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
            .receive(messageType, argument: argument)
    }
}

/// Keeps the displays from sleeping on idle while a tablet session is accepted (T-128, user decision 2026-10-02):
/// the tablet's own screen timeout ends an unused session, after which the Mac follows its normal energy settings.
/// Thin `IOPMAssertionCreateWithName(PreventUserIdleDisplaySleep)` wrapper. A forced sleep (`pmset sleepnow`, Apple
/// menu > Sleep, lid) is not blocked by this assertion.
final class DisplaySleepAssertion: @unchecked Sendable {
    /// `kIOPMAssertPreventUserIdleDisplaySleep` (a `CFSTR` macro, not imported into Swift).
    static let type = "PreventUserIdleDisplaySleep"
    private static let name = "MateBridge: tablet session active"
    private let lock = NSLock()
    private var id: IOPMAssertionID?

    enum Change: Equatable {
        case none
        case held
        case released
        /// IOKit refused; the hex result for the log.
        case failed(String)
    }

    var isHeld: Bool { lock.withLock { id != nil } }

    /// Takes the assertion unless it is already held.
    func hold() -> Change {
        lock.withLock {
            guard id == nil else { return .none }
            var newID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(Self.type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     Self.name as CFString, &newID)
            guard result == kIOReturnSuccess else {
                return .failed(String(format: "0x%08x", UInt32(bitPattern: result)))
            }
            id = newID
            return .held
        }
    }

    /// Releases the assertion if held.
    func release() -> Change {
        lock.withLock {
            guard let held = id else { return .none }
            id = nil
            let result = IOPMAssertionRelease(held)
            return result == kIOReturnSuccess ? .released : .failed(String(format: "0x%08x", UInt32(bitPattern: result)))
        }
    }

    deinit {
        if let id { IOPMAssertionRelease(id) }
    }
}
