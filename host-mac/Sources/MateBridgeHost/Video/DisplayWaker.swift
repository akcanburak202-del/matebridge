import Foundation
import IOKit.pwr_mgt
import MateBridgeCore
import ScreenCaptureKit

/// Wakes the Mac's displays by declaring local user activity (T-081). Thin IOKit wrapper; `DisplayWakePolicy`
/// decides when.
///
/// `IOPMAssertionDeclareUserActivity` powers the displays on and postpones display sleep only up to the user's own
/// display sleep setting, like a key press would. It does not hold the display awake (no
/// `PreventUserIdleDisplaySleep`), and the screen lock still engages as usual.
final class DisplayWaker: @unchecked Sendable {
    private static let assertionName = "MateBridge: tablet session lost its display"
    private let lock = NSLock()
    /// Returned by the previous call and passed back, as the header asks for repeated declarations.
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID)

    /// Declares user activity now. Returns nil on success, otherwise the IOKit result as hex for the log.
    @discardableResult
    func declareUserActivity() -> String? {
        lock.withLock {
            var id = assertionID
            let result = IOPMAssertionDeclareUserActivity(Self.assertionName as CFString, kIOPMUserActiveLocal, &id)
            guard result == kIOReturnSuccess else { return String(format: "0x%08x", UInt32(bitPattern: result)) }
            assertionID = id
            return nil
        }
    }

    /// The display-sleep causes a wake can fix (SCStream -3815, virtual display creation returning nil); nil for
    /// anything else.
    static func reason(for error: Error) -> DisplayWakeReason? {
        if case VirtualDisplayError.creationFailed = error { return .displayCreateNil }
        let ns = error as NSError
        guard ns.domain == SCStreamErrorDomain else { return nil }
        return DisplayWakeReason.fromScreenCaptureError(code: ns.code)
    }
}
