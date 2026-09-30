import Foundation
@testable import MateBridgeCore

enum Hex {
    static func bytes(_ s: String) -> [UInt8] {
        precondition(s.count % 2 == 0)
        var out: [UInt8] = []
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    static func string(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
}

/// `protocol/fixtures/crypto_vectors.json` (PROTOCOL.md 9), read straight from the repository.
struct CryptoVectors: @unchecked Sendable {
    let root: [String: Any]

    static let shared: CryptoVectors = {
        let data = try! Data(contentsOf: Fixtures.directory.appendingPathComponent("crypto_vectors.json"))
        return CryptoVectors(root: try! JSONSerialization.jsonObject(with: data) as! [String: Any])
    }()

    func string(_ path: String...) -> String {
        var node: Any = root
        for key in path { node = (node as! [String: Any])[key]! }
        return node as! String
    }

    func bytes(_ path: String...) -> [UInt8] {
        var node: Any = root
        for key in path { node = (node as! [String: Any])[key]! }
        return Hex.bytes(node as! String)
    }

    struct Frame {
        let key: [UInt8], counter: UInt64, type: UInt8, payload: [UInt8], nonce: [UInt8], frame: [UInt8]
    }

    var frames: [Frame] {
        (root["frames"] as! [[String: String]]).map { f in
            Frame(key: Hex.bytes(f["key"]!), counter: UInt64(f["counter"]!)!,
                  type: UInt8(f["type"]!.dropFirst(2), radix: 16)!, payload: Hex.bytes(f["payload"]!),
                  nonce: Hex.bytes(f["nonce"]!), frame: Hex.bytes(f["frame"]!))
        }
    }
}

/// A tablet as the host sees it: real ephemeral key, real derivation. Used to drive the machine end to end.
struct TestClient {
    let deviceID: DeviceID
    let eph: EphemeralKeyPair
    var hello: Hello
    var schedule: SessionKeySchedule?
    var sealer: RecordSealer?      // c2h
    var inbound: ControlInbound?   // h2c

    /// Every client uses the same ephemeral key unless told otherwise; the machine only needs a valid point.
    static let defaultEph = try! EphemeralKeyPair(rawPrivateKey: Hex.bytes(
        "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c101"))

    init(device: UInt8 = 1, name: String = "Pad", version: UInt16 = ProtocolConstants.protocolVersion,
         eph: EphemeralKeyPair = TestClient.defaultEph) {
        deviceID = DeviceID(bytes: [UInt8](repeating: device, count: 16))!
        self.eph = eph
        hello = Hello(protocolVersion: version, deviceID: deviceID, screenWidthPx: 2800, screenHeightPx: 1840,
                      densityDpi: 360, maxRefreshHz: 144, capabilities: [.pen, .touch], deviceName: name,
                      clientNonce: [UInt8](repeating: 0xc0, count: 16), clientEphPub: eph.publicKeyBytes)
    }

    var message: Message { .hello(hello) }

    /// Derives the session keys from the host's first HELLO_ACK (what the Android client does).
    mutating func receiveFirstAck(_ ack: HelloAck, pairKey: SecretBytes?) throws {
        let ecdh = try eph.sharedSecret(withPeerPublicKey: ack.hostEphPub)
        let s = try SessionKeySchedule.derive(ecdh: ecdh, pairKey: pairKey,
                                              helloPayload: Message.hello(hello).encodePayload(),
                                              ackPayload: Message.helloAck(ack).encodePayload())
        schedule = s
        sealer = RecordSealer(key: s.control.c2h, maxPayload: ProtocolConstants.maxControlPayload)
        var inb = ControlInbound()
        try inb.enableEncryption(key: s.control.h2c)
        inbound = inb
    }

    /// Message the client sends after the handshake, as the host would receive it.
    mutating func seal(_ m: Message) throws -> [UInt8] { try m.sealed(using: &sealer!) }

    /// Opens what the host sent after the first ack.
    mutating func open(_ bytes: [UInt8]) throws -> [Message] {
        inbound!.append(bytes)
        var out: [Message] = []
        while let m = try inbound!.nextMessage() { out.append(m) }
        return out
    }
}
