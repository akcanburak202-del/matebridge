import Foundation
import IOKit
import IOKit.hidsystem

/// The Mac's Caps Lock state: read it, set it. The one type that knows how (PROTOCOL.md section 4: Caps Lock is never
/// injected as a key; the host sets the Mac's lock state to the tablet's instead). A seam so that tests and the
/// `InputController` can run without touching the system.
public protocol CapsLockControlling: Sendable {
    /// nil when the state cannot be read.
    func isOn() -> Bool?
    /// Sets the absolute state (not a toggle). False when the system refused.
    func set(_ on: Bool) -> Bool
}

/// `IOHIDGetModifierLockState` / `IOHIDSetModifierLockState` on the HID system service. Unlike a synthetic Caps Lock
/// key event these change the real lock state and its LED. Whether the set call needs a privacy permission beyond
/// Accessibility is unverified on macOS 27; a refusal is reported by the return value and logged once by the poster.
public final class SystemCapsLock: CapsLockControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var connection: io_connect_t = 0

    public init() {}

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// The HID system connection, opened on first use. Caller holds `lock`.
    private func hidConnection() -> io_connect_t? {
        if connection != 0 { return connection }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &opened) == KERN_SUCCESS,
              opened != 0 else { return nil }
        connection = opened
        return opened
    }

    public func isOn() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = hidConnection() else { return nil }
        var state = false
        guard IOHIDGetModifierLockState(conn, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else { return nil }
        return state
    }

    public func set(_ on: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let conn = hidConnection() else { return false }
        return IOHIDSetModifierLockState(conn, Int32(kIOHIDCapsLockState), on) == KERN_SUCCESS
    }
}
