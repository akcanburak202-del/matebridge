import Foundation
import MateBridgeCore

/// How each tablet reached the Mac most recently (T-088), written by `SessionServer` and read by `StreamCoordinator`
/// for its transport-dependent settings and logs.
///
/// The two are wired together in `MateBridgeApp/main.swift` through callbacks that carry only the HELLO, so the
/// transport travels here, keyed by device. The server records it when a HELLO arrives (before the session machine can
/// ask for its `STREAM_CONFIG`) and again when that connection becomes the session. Bounded: at most `capacity`
/// devices; the table is cleared when a new one would exceed it.
final class SessionTransportBoard: @unchecked Sendable {
    static let shared = SessionTransportBoard()
    static let capacity = 16

    private let lock = NSLock()
    private var transports: [DeviceID: SessionTransport] = [:]

    func record(_ transport: SessionTransport, for device: DeviceID) {
        lock.withLock {
            if transports[device] == nil, transports.count >= Self.capacity { transports.removeAll() }
            transports[device] = transport
        }
    }

    /// nil: never recorded (the caller treats the transport as unknown and applies no transport knob).
    func transport(for device: DeviceID) -> SessionTransport? {
        lock.withLock { transports[device] }
    }
}
