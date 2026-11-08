import Foundation

/// The adb serial of the USB device while `UsbTunnelWatcher` sees its tunnels up (T-389). The watcher is the only
/// writer; readers get nil whenever the tunnels are not up (no cable, adb down, watcher off). The serial is only ever
/// used as an argument to adb and is never logged.
final class UsbDeviceRegistry: @unchecked Sendable {
    static let shared = UsbDeviceRegistry()

    private let lock = NSLock()
    private var current: String?
    private var observer: (@Sendable () -> Void)?

    var serial: String? { lock.withLock { current } }

    /// Called by the watcher on every probe; the observer is notified (outside the lock) only when the value changed.
    func publish(_ serial: String?) {
        let notify: (@Sendable () -> Void)? = lock.withLock {
            guard serial != current else { return nil }
            current = serial
            return observer
        }
        notify?()
    }

    /// One observer at most (the 120 Hz hold). It may run on any queue and must not block. nil removes it.
    func setObserver(_ observer: (@Sendable () -> Void)?) {
        lock.withLock { self.observer = observer }
    }
}
