import Dispatch
import Foundation
import dnssd

/// Bonjour (DNS-SD) registration of a listening port (T-111). `NWListener.service` does this for a Network.framework
/// listener; a kernel-socket listener (`BsdTcpListener`) has no such hook, so the service is registered on its own with
/// `DNSServiceRegister` (dns_sd, part of the system). Same record as the `NWListener.Service` it replaces: instance
/// name, service type, TXT record, the bound port. On a name conflict mDNSResponder renames the instance itself
/// (no `kDNSServiceFlagsNoAutoRename`), as Network.framework does.
///
/// Callbacks and events run on `queue`. The advertiser keeps itself alive until `cancel()`, which the owner must call.
public final class BonjourAdvertiser: @unchecked Sendable {
    public enum Event: Sendable, Equatable {
        /// The service is registered (possibly under a renamed instance name).
        case registered
        /// The registration failed or broke (e.g. mDNSResponder restarted). The advertiser is done; register again.
        case failed(code: Int32)
    }

    /// Where the record is visible. `.localOnly` stays on this Mac (tests).
    public enum Scope: Sendable {
        case allInterfaces
        case localOnly
    }

    /// DNS-SD instance names are at most 63 UTF-8 bytes.
    public static let maxNameBytes = 63
    /// One TXT entry ("key=value") is at most 255 bytes.
    public static let maxTxtEntryBytes = 255

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var ref: DNSServiceRef?
    private var cancelled = false
    private let handler: @Sendable (Event) -> Void

    /// Registers `type` (e.g. `_matebridge._tcp`) on `port`. Throws the dns_sd error code when the request cannot even
    /// be made (then nothing is registered and nothing needs cancelling).
    public init(name: String, type: String, port: UInt16, txt: [(key: String, value: String)],
                scope: Scope = .allInterfaces, queue: DispatchQueue,
                handler: @escaping @Sendable (Event) -> Void) throws {
        self.queue = queue
        self.handler = handler
        let record = Self.txtRecord(txt)
        let interface: UInt32 = scope == .localOnly ? kDNSServiceInterfaceIndexLocalOnly : 0
        var newRef: DNSServiceRef?
        // The registration holds one reference to the advertiser, released when `cancel()` deallocates it.
        let context = Unmanaged.passRetained(self)
        let err = record.withUnsafeBytes { txtBytes in
            DNSServiceRegister(&newRef, 0, interface, Self.instanceName(name), type, nil, nil, port.bigEndian,
                               UInt16(txtBytes.count), txtBytes.baseAddress, Self.registerReply,
                               context.toOpaque())
        }
        guard err == kDNSServiceErr_NoError, let newRef else {
            context.release()
            throw BonjourError(code: err)
        }
        let queued = DNSServiceSetDispatchQueue(newRef, queue)
        guard queued == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(newRef)
            context.release()
            throw BonjourError(code: queued)
        }
        ref = newRef
    }

    /// Withdraws the record. Idempotent, any thread; the reference is deallocated on `queue` (dns_sd requires the
    /// queue it was set to), and no event is delivered afterwards.
    public func cancel() {
        let old: DNSServiceRef? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { ref = nil }
            return ref
        }
        guard let old else { return }
        let box = RefBox(old)
        queue.async { [self] in
            DNSServiceRefDeallocate(box.ref)
            Unmanaged.passUnretained(self).release()  // the registration's reference
        }
    }

    private func deliver(_ error: DNSServiceErrorType) {
        guard !lock.withLock({ cancelled }) else { return }
        handler(error == kDNSServiceErr_NoError ? .registered : .failed(code: error))
    }

    private static let registerReply: DNSServiceRegisterReply = { _, _, error, _, _, _, context in
        guard let context else { return }
        Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue().deliver(error)
    }

    // MARK: Pure helpers

    /// The instance name as registered: at most `maxNameBytes` UTF-8 bytes, cut at a character boundary; "Mac" when
    /// empty.
    public static func instanceName(_ name: String) -> String {
        var out = ""
        var bytes = 0
        for ch in name {
            let n = String(ch).utf8.count
            guard bytes + n <= maxNameBytes else { break }
            out.append(ch)
            bytes += n
        }
        return out.isEmpty ? "Mac" : out
    }

    /// DNS-SD TXT record bytes: each "key=value" prefixed by its length; entries longer than 255 bytes are left out.
    /// An empty record is the single empty string (one zero byte), as RFC 6763 section 6.1 asks.
    public static func txtRecord(_ entries: [(key: String, value: String)]) -> [UInt8] {
        var out: [UInt8] = []
        for (key, value) in entries {
            let entry = Array("\(key)=\(value)".utf8)
            guard !key.isEmpty, entry.count <= maxTxtEntryBytes else { continue }
            out.append(UInt8(entry.count))
            out += entry
        }
        return out.isEmpty ? [0] : out
    }
}

public struct BonjourError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: Int32
    public var description: String { "dnssd:\(code)" }
}

private final class RefBox: @unchecked Sendable {
    let ref: DNSServiceRef
    init(_ ref: DNSServiceRef) { self.ref = ref }
}
