import Foundation

/// Byte buffer for child-process output with a hard cap. Extra bytes are dropped (the pipe is still drained by the
/// caller) and `truncated` is set, so callers can reject partial output instead of parsing it.
public struct BoundedCapture: Sendable {
    public static let defaultLimit = 64 * 1024

    public let limit: Int
    public private(set) var data = Data()
    public private(set) var truncated = false

    public init(limit: Int = BoundedCapture.defaultLimit) { self.limit = limit }

    public mutating func append(_ chunk: Data) {
        let room = limit - data.count
        if chunk.count <= room {
            data.append(chunk)
        } else {
            if room > 0 { data.append(chunk.prefix(room)) }
            truncated = true
        }
    }

    public var string: String { String(decoding: data, as: UTF8.self) }
}

/// Retry plan for removing `adb reverse` tunnels when USB mode is switched off: bounded attempts with backoff.
public struct TunnelRemoval: Sendable {
    public static let maxAttempts = 5
    public static let baseDelay: TimeInterval = 0.5

    public enum Outcome: Equatable, Sendable {
        case done
        case retry(after: TimeInterval, ports: [UInt16])
        case gaveUp(ports: [UInt16])
    }

    public private(set) var pending: [UInt16]
    private var attempts = 0

    public init(ports: [UInt16]) { pending = ports }

    /// Report what is still installed after an attempt (`nil` = could not find out: everything counts as pending).
    public mutating func finishAttempt(stillPresent: Set<UInt16>?) -> Outcome {
        attempts += 1
        if let stillPresent { pending = pending.filter { stillPresent.contains($0) } }
        if pending.isEmpty { return .done }
        if attempts >= Self.maxAttempts { return .gaveUp(ports: pending) }
        return .retry(after: Self.baseDelay * Double(1 << (attempts - 1)), ports: pending)
    }
}

/// The state of the start-at-login registration as far as the menu logic cares (mirrors `SMAppService.Status`).
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    /// Registered but the user has not approved it yet in System Settings.
    case requiresApproval
    case off

    /// The user asked for it (a pending approval counts), so the toggle must be able to cancel it.
    public var isRequested: Bool { self != .off }
    public var menuTitle: String {
        self == .requiresApproval ? "Oturum açılışında başlat (onay bekliyor)" : "Oturum açılışında başlat"
    }
}
