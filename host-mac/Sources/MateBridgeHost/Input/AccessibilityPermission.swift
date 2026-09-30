import ApplicationServices
import Foundation

/// Whether this process may post input events (Accessibility, TCC). A protocol so nothing has to ask the real system
/// to exercise the code that depends on the answer.
public protocol AccessibilityChecking: Sendable {
    func isTrusted() -> Bool
}

/// The real check. `AXIsProcessTrusted` never prompts. TCC keys the grant to the app's bundle ID and signing
/// identity (host-mac/AGENTS.md), so MateBridge.app asks for it under its own name.
public struct SystemAccessibility: AccessibilityChecking {
    public init() {}

    public func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Shows the system's permission prompt when the process is not trusted (it does nothing when it already is, or
    /// when the user has answered before). Returns the current trust. UI only: the app calls it once at launch.
    @discardableResult
    public static func requestPrompt() -> Bool {
        // The literal is `kAXTrustedCheckOptionPrompt`; the C global is not usable under Swift 6 concurrency checking.
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
}
