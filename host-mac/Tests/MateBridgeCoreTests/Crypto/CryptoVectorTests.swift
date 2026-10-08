import Foundation
import Testing
@testable import MateBridgeCore

// Every value of protocol/fixtures/crypto_vectors.json is reproduced here from the fixed inputs
// (PROTOCOL.md 9). The Kotlin side runs the same file, so both implementations agree byte for byte.

private let v = CryptoVectors.shared

private func keyPair(_ name: String) throws -> EphemeralKeyPair {
    try EphemeralKeyPair(rawPrivateKey: v.bytes("inputs", name))
}

private func schedule(paired: Bool) throws -> SessionKeySchedule {
    let ecdh = v.bytes("ecdh")
    return try SessionKeySchedule.derive(
        ecdh: ecdh, pairKey: paired ? SecretBytes(v.bytes("inputs", "pair_key")) : nil,
        helloPayload: v.bytes("inputs", "hello_payload"),
        ackPayload: v.bytes("inputs", paired ? "hello_ack_paired_payload" : "hello_ack_pairing_payload"))
}

@Suite struct CryptoVectorTests {
    @Test func publicKeysAndEcdhMatchOnBothSides() throws {
        let client = try keyPair("client_eph_priv"), host = try keyPair("host_eph_priv")
        #expect(client.publicKeyBytes == v.bytes("inputs", "client_eph_pub"))
        #expect(host.publicKeyBytes == v.bytes("inputs", "host_eph_pub"))
        let fromClient = try client.sharedSecret(withPeerPublicKey: host.publicKeyBytes)
        let fromHost = try host.sharedSecret(withPeerPublicKey: client.publicKeyBytes)
        #expect(fromClient == v.bytes("ecdh"))
        #expect(fromHost == fromClient)
    }

    @Test func fixtureHandshakePayloadsAreTheGoldenFixtures() {
        // The vectors hash the golden hello / hello_ack payloads (frame header stripped).
        #expect(v.bytes("inputs", "hello_payload") == Array(Fixtures.bytes("hello").dropFirst(5)))
        #expect(v.bytes("inputs", "hello_ack_paired_payload") == Array(Fixtures.bytes("hello_ack").dropFirst(5)))
        #expect(v.bytes("inputs", "hello_ack_pairing_payload")
                == Array(Fixtures.bytes("hello_ack_pending").dropFirst(5)))
    }

    @Test func pairedSchedule() throws {
        let s = try schedule(paired: true)
        #expect(s.mode == .paired)
        #expect(s.transcriptHash == v.bytes("paired", "transcript_hash"))
        #expect(s.prkBytes == v.bytes("paired", "prk"))
        #expect(v.bytes("inputs", "pair_key") + v.bytes("ecdh") == v.bytes("paired", "ikm"))
        #expect(s.control.c2h.bytes == v.bytes("paired", "key_control_c2h"))
        #expect(s.control.h2c.bytes == v.bytes("paired", "key_control_h2c"))
        let video = try #require(s.videoKeys(nonce: v.bytes("inputs", "video_nonce")))
        #expect(video.c2h.bytes == v.bytes("paired", "key_video_c2h"))
        #expect(video.h2c.bytes == v.bytes("paired", "key_video_h2c"))
        let files = try #require(s.filesKeys(clientNonce: v.bytes("inputs", "client_files_nonce"),
                                             hostNonce: v.bytes("inputs", "host_files_nonce")))
        #expect(files.c2h.bytes == v.bytes("paired", "key_files_c2h"))
        #expect(files.h2c.bytes == v.bytes("paired", "key_files_h2c"))
        #expect(s.pairingCode == nil && s.newPairKey == nil)
    }

    @Test func pairingSchedule() throws {
        let s = try schedule(paired: false)
        #expect(s.mode == .pairing)
        #expect(s.transcriptHash == v.bytes("pairing", "transcript_hash"))
        #expect(v.bytes("ecdh") == v.bytes("pairing", "ikm"))
        #expect(s.prkBytes == v.bytes("pairing", "prk"))
        #expect(s.control.c2h.bytes == v.bytes("pairing", "key_control_c2h"))
        #expect(s.control.h2c.bytes == v.bytes("pairing", "key_control_h2c"))
        let video = try #require(s.videoKeys(nonce: v.bytes("inputs", "video_nonce")))
        #expect(video.c2h.bytes == v.bytes("pairing", "key_video_c2h"))
        #expect(video.h2c.bytes == v.bytes("pairing", "key_video_h2c"))
        let files = try #require(s.filesKeys(clientNonce: v.bytes("inputs", "client_files_nonce"),
                                             hostNonce: v.bytes("inputs", "host_files_nonce")))
        #expect(files.c2h.bytes == v.bytes("pairing", "key_files_c2h"))
        #expect(files.h2c.bytes == v.bytes("pairing", "key_files_h2c"))
        #expect(KDF.expand(prk: v.bytes("pairing", "prk"), info: "MB1 sas", count: 4) == v.bytes("pairing", "sas_bytes"))
        #expect(s.pairingCode?.digits == v.string("pairing", "sas"))
        #expect(s.newPairKey?.bytes == v.bytes("pairing", "new_pair_key"))
    }

    @Test func pairedAndPairingSchedulesAreIndependent() throws {
        #expect(try schedule(paired: true).prkBytes != schedule(paired: false).prkBytes)
    }

    @Test func sealedFramesMatchByteForByte() throws {
        for f in v.frames {
            var sealer = RecordSealer(key: SecretBytes(f.key), maxPayload: 16_777_216, startingCounter: f.counter)
            #expect(try sealer.seal(type: f.type, payload: f.payload) == f.frame)
            #expect(sealer.counter == f.counter + 1)
            // Frame layout: length (plaintext + 16) || ciphertext || tag.
            let length = Int(f.frame[0]) | Int(f.frame[1]) << 8 | Int(f.frame[2]) << 16 | Int(f.frame[3]) << 24
            #expect(length == f.payload.count + 1 + 16 && f.frame.count == 4 + length)
            #expect(f.nonce == [0, 0, 0, 0] + (0..<8).map { UInt8(truncatingIfNeeded: f.counter >> (8 * UInt64($0))) })
        }
    }

    @Test func controlFramesDecode() throws {
        let frames = v.frames
        // c2h counter 0 and 1: same PING payload, different nonce, both authenticate in order.
        var d = RecordDecoder(key: SecretBytes(frames[0].key), connection: .control)
        d.append(frames[0].frame + frames[1].frame)
        let ping = Message.ping(Ping(seq: 7, senderTimeUs: 1_127_500_000_000))
        #expect(try d.nextMessage() == ping)
        #expect(try d.nextMessage() == ping)
        #expect(try d.nextMessage() == nil)
        #expect(d.counter == 2)
        #expect(frames[0].frame != frames[1].frame)  // the counter changes the ciphertext
        // h2c counter 5 (independent key and counter).
        var h = RecordDecoder(key: SecretBytes(frames[2].key), connection: .control, startingCounter: 5)
        h.append(frames[2].frame)
        #expect(try h.nextMessage() == .releaseAll(ReleaseReason(rawValue: 1)))
    }

    @Test func emptyPayloadVideoFrameAuthenticatesThenFailsAsProtocolError() throws {
        let f = v.frames[3]
        var d = RecordDecoder(key: SecretBytes(f.key), connection: .video)
        d.append(f.frame)
        // The record is authentic; its (empty) VIDEO_FRAME payload is then too short for the message layout.
        #expect(throws: ProtocolError.payloadTooShort(type: 0x41)) { try d.nextMessage() }
    }

    @Test func fileConnectionFramesDecodeUnderTheFileKeys() throws {
        let frames = v.frames
        #expect(frames.count == 7)
        // c2h counter 0: the proof PING; counter 1: the tablet's first reply FILES_DATA. h2c counter 0: the host's request.
        var c2h = RecordDecoder(key: SecretBytes(frames[4].key), connection: .files)
        c2h.append(frames[4].frame + frames[6].frame)
        #expect(try c2h.nextMessage() == .ping(Ping(seq: 1, senderTimeUs: 1_127_500_100_000)))
        #expect(try c2h.nextMessage() == .filesData(FilesData(data: Array("HTTP/1.1 200 OK".utf8))))
        #expect(try c2h.nextMessage() == nil)
        #expect(c2h.counter == 2)
        var h2c = RecordDecoder(key: SecretBytes(frames[5].key), connection: .files)
        h2c.append(frames[5].frame)
        #expect(try h2c.nextMessage() == .filesData(FilesData(data: Array("OPTIONS / HTTP/1.1".utf8))))
        // The two directions and the control keys are independent: a record never opens under another key.
        var wrong = RecordDecoder(key: SecretBytes(frames[5].key), connection: .files)
        wrong.append(frames[4].frame)
        #expect(throws: CryptoError.authenticationFailed) { try wrong.nextMessage() }
        #expect(frames[4].key != frames[5].key)
        #expect(frames[4].key != v.frames[0].key)
    }

    @Test func fileKeysDependOnBothNoncesAndDieWithThePrk() throws {
        let s = try schedule(paired: true)
        let client = v.bytes("inputs", "client_files_nonce"), host = v.bytes("inputs", "host_files_nonce")
        let base = try #require(s.filesKeys(clientNonce: client, hostNonce: host))
        var otherHost = host
        otherHost[0] ^= 1
        var otherClient = client
        otherClient[15] ^= 1
        let a = try #require(s.filesKeys(clientNonce: client, hostNonce: otherHost))
        let b = try #require(s.filesKeys(clientNonce: otherClient, hostNonce: host))
        #expect(a.c2h != base.c2h && a.h2c != base.h2c)
        #expect(b.c2h != base.c2h && b.h2c != base.h2c)
        // Swapping the nonces is another connection too (client first, host second).
        let swapped = try #require(s.filesKeys(clientNonce: host, hostNonce: client))
        #expect(swapped.c2h != base.c2h)
        #expect(s.filesKeys(clientNonce: [1, 2, 3], hostNonce: host) == nil)
        #expect(s.filesKeys(clientNonce: client, hostNonce: []) == nil)
        s.wipe()
        #expect(s.filesKeys(clientNonce: client, hostNonce: host) == nil)
        // Keys handed out earlier are unaffected.
        #expect(base.c2h.bytes == v.bytes("paired", "key_files_c2h"))
    }

    @Test func fileConnectionRecordsCarryTheFullPayloadLimit() throws {
        let s = try schedule(paired: true)
        let keys = try #require(s.filesKeys(clientNonce: v.bytes("inputs", "client_files_nonce"),
                                            hostNonce: v.bytes("inputs", "host_files_nonce")))
        var sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxControlPayload)
        var decoder = RecordDecoder(key: keys.h2c, connection: .files)
        let biggest = Message.filesData(FilesData(data: [UInt8](repeating: 0x5a, count: ProtocolConstants.filesDataMax)))
        let record = try biggest.sealed(using: &sealer)
        #expect(record.count == 4 + ProtocolConstants.maxControlPayload + ProtocolConstants.recordOverhead)
        var offset = 0
        while offset < record.count {  // the receive loop hands over at most 64 KiB at a time
            let end = min(offset + FrameDecoder.maxReadChunk, record.count)
            decoder.append(Array(record[offset..<end]))
            offset = end
        }
        #expect(try decoder.nextMessage() == biggest)
        // One byte more is refused before sealing, and a header that announces more is refused on arrival.
        #expect(throws: ProtocolError.invalidField("size")) {
            try Message.filesData(FilesData(data: [UInt8](repeating: 0, count: ProtocolConstants.filesDataMax + 1)))
                .sealed(using: &sealer)
        }
        var tooLong = RecordDecoder(key: keys.h2c, connection: .files)
        let announced = UInt32(ProtocolConstants.maxControlPayload + ProtocolConstants.recordOverhead + 1)
        tooLong.append((0..<4).map { UInt8(truncatingIfNeeded: announced >> (8 * UInt32($0))) })
        #expect(throws: CryptoError.invalidRecordLength(announced)) { try tooLong.nextMessage() }
    }

    @Test func everyCorruptedByteIsRejected() throws {
        for (index, f) in v.frames.enumerated() {
            for position in 0..<f.frame.count {
                var bad = f.frame
                bad[position] ^= 0x01
                let connection: FrameDecoder.Connection = index == 3 ? .video : (index >= 4 ? .files : .control)
                var d = RecordDecoder(key: SecretBytes(f.key), connection: connection, startingCounter: f.counter)
                d.append(bad)
                do {
                    let m = try d.nextMessage()
                    // A longer length byte just means "wait for more bytes"; it never yields a message.
                    #expect(m == nil, "frame \(index) byte \(position) produced a message")
                } catch is CryptoError {
                } catch {
                    Issue.record("frame \(index) byte \(position): \(error)")
                }
            }
        }
    }

    @Test func ciphertextAndTagFlipsAreAuthenticationFailures() throws {
        let f = v.frames[0]
        for position in 4..<f.frame.count {
            var bad = f.frame
            bad[position] ^= 0x80
            var d = RecordDecoder(key: SecretBytes(f.key), connection: .control)
            d.append(bad)
            #expect(throws: CryptoError.authenticationFailed) { try d.nextMessage() }
            #expect(throws: CryptoError.decoderFailed) { try d.nextMessage() }  // failed for good
        }
    }

    @Test func wrongKeyAndWrongDirectionAreRejected() throws {
        let f = v.frames[0]
        var wrongKey = RecordDecoder(key: SecretBytes(v.frames[2].key), connection: .control)
        wrongKey.append(f.frame)
        #expect(throws: CryptoError.authenticationFailed) { try wrongKey.nextMessage() }
    }

    @Test func replayedOrReorderedRecordsAreRejected() throws {
        let frames = v.frames
        var replay = RecordDecoder(key: SecretBytes(frames[0].key), connection: .control)
        replay.append(frames[0].frame)
        #expect(try replay.nextMessage() != nil)
        replay.append(frames[0].frame)  // counter 0 again, but 1 is expected
        #expect(throws: CryptoError.authenticationFailed) { try replay.nextMessage() }

        var reordered = RecordDecoder(key: SecretBytes(frames[0].key), connection: .control)
        reordered.append(frames[1].frame)  // counter 1 first
        #expect(throws: CryptoError.authenticationFailed) { try reordered.nextMessage() }
    }

    @Test func directionsKeepIndependentCounters() throws {
        let s = try schedule(paired: true)
        var c2h = RecordSealer(key: s.control.c2h, maxPayload: 65_536)
        var h2c = RecordSealer(key: s.control.h2c, maxPayload: 65_536)
        _ = try c2h.seal(type: 0x20, payload: Array(repeating: 0, count: 12))
        _ = try c2h.seal(type: 0x20, payload: Array(repeating: 0, count: 12))
        #expect(c2h.counter == 2 && h2c.counter == 0)
        _ = try h2c.seal(type: 0x20, payload: Array(repeating: 0, count: 12))
        #expect(c2h.counter == 2 && h2c.counter == 1)
    }

    @Test func byteAtATimeDelivery() throws {
        let frames = v.frames
        var d = RecordDecoder(key: SecretBytes(frames[0].key), connection: .control)
        var out: [Message] = []
        for b in frames[0].frame + frames[1].frame {
            d.append([b])
            while let m = try d.nextMessage() { out.append(m) }
        }
        #expect(out.count == 2)
    }

    @Test func lengthIsCheckedAsSoonAsItsFourBytesArrive() {
        let key = SecretBytes(v.frames[0].key)
        func header(_ length: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * UInt32($0))) } }

        var tooShort = RecordDecoder(key: key, connection: .control)
        tooShort.append(header(16))  // < 17: no room for type byte and tag
        #expect(throws: CryptoError.invalidRecordLength(16)) { try tooShort.nextMessage() }

        var tooLong = RecordDecoder(key: key, connection: .control)
        tooLong.append(header(UInt32(ProtocolConstants.maxControlPayload + 17 + 1)))  // nothing else sent
        #expect(throws: CryptoError.invalidRecordLength(UInt32(ProtocolConstants.maxControlPayload + 18))) {
            try tooLong.nextMessage()
        }

        var video = RecordDecoder(key: key, connection: .video)
        video.append(header(UInt32(ProtocolConstants.maxVideoPayload + 18)))
        #expect(throws: CryptoError.invalidRecordLength(UInt32(ProtocolConstants.maxVideoPayload + 18))) {
            try video.nextMessage()
        }

        // The limit itself is fine (the decoder just waits for the rest).
        var atLimit = RecordDecoder(key: key, connection: .control)
        atLimit.append(header(UInt32(ProtocolConstants.maxControlPayload + 17)))
        #expect(throws: Never.self) { _ = try atLimit.nextMessage() }
    }

    @Test func bufferingStaysBounded() {
        var d = RecordDecoder(key: SecretBytes(v.frames[0].key), connection: .control)
        d.append([UInt8](repeating: 0, count: FrameDecoder.maxReadChunk + 1))
        #expect(throws: CryptoError.chunkTooLarge) { try d.nextMessage() }
    }

    @Test func counterExhaustion() throws {
        let key = SecretBytes(v.frames[0].key)
        var sealer = RecordSealer(key: key, maxPayload: 65_536, startingCounter: RecordSealer.counterLimit - 1)
        let last = try sealer.seal(type: 0x20, payload: Array(repeating: 0, count: 12))
        #expect(throws: CryptoError.counterExhausted) { try sealer.seal(type: 0x20, payload: []) }
        #expect(sealer.counter == RecordSealer.counterLimit)

        var d = RecordDecoder(key: key, connection: .control, startingCounter: RecordSealer.counterLimit - 1)
        d.append(last)
        #expect(try d.nextMessage() != nil)
        d.append(last)
        #expect(throws: CryptoError.counterExhausted) { try d.nextMessage() }
    }

    @Test func oversizedPayloadIsRefusedBeforeSealing() {
        var sealer = RecordSealer(key: SecretBytes(v.frames[0].key), maxPayload: 65_536)
        #expect(throws: ProtocolError.payloadTooLarge(length: 65_537, limit: 65_536)) {
            try sealer.seal(type: 0x20, payload: [UInt8](repeating: 0, count: 65_537))
        }
        #expect(sealer.counter == 0)  // a refused frame does not consume a counter
    }

    @Test func invalidPublicKeysAreRejected() throws {
        let host = try keyPair("host_eph_priv")
        let good = v.bytes("inputs", "client_eph_pub")
        var offCurve = good
        offCurve[64] ^= 0x01
        var compressed = Array(good.prefix(33))
        compressed[0] = 0x02
        let cases: [[UInt8]] = [[], [UInt8](repeating: 0, count: 65), Array(good.dropLast()), offCurve, compressed,
                                [0x04] + [UInt8](repeating: 0, count: 64), good + [0]]
        for bad in cases {
            #expect(throws: CryptoError.invalidPublicKey) { try host.sharedSecret(withPeerPublicKey: bad) }
        }
        #expect(throws: CryptoError.invalidKeyLength) { try EphemeralKeyPair(rawPrivateKey: [1, 2, 3]) }
    }

    @Test func freshEphemeralKeysAgree() throws {
        let a = EphemeralKeyPair(), b = EphemeralKeyPair()
        #expect(try a.sharedSecret(withPeerPublicKey: b.publicKeyBytes) == b.sharedSecret(withPeerPublicKey: a.publicKeyBytes))
        #expect(a.publicKeyBytes != b.publicKeyBytes)
    }

    @Test func wrongSizedKeyMaterialIsRefused() {
        #expect(throws: CryptoError.invalidKeyLength) {
            try SessionKeySchedule.derive(ecdh: [1, 2], pairKey: nil, helloPayload: [], ackPayload: [])
        }
        #expect(throws: CryptoError.invalidKeyLength) {
            try SessionKeySchedule.derive(ecdh: [UInt8](repeating: 1, count: 32), pairKey: SecretBytes([1]),
                                          helloPayload: [], ackPayload: [])
        }
    }

    @Test func prkIsWipedAtSessionEnd() throws {
        let s = try schedule(paired: true)
        let nonce = v.bytes("inputs", "video_nonce")
        #expect(s.videoKeys(nonce: nonce) != nil)
        #expect(s.videoKeys(nonce: [1, 2, 3]) == nil)
        s.wipe()
        #expect(s.prkBytes == nil)
        #expect(s.secret.rawStorage.allSatisfy { $0 == 0 })
        #expect(s.videoKeys(nonce: nonce) == nil)
    }

    @Test func secretsDescribeThemselvesAsRedacted() throws {
        let s = try schedule(paired: false)
        let rendered = [String(describing: s.control), String(reflecting: s.control),
                        "\(s.control.c2h)", "\(String(describing: s.pairingCode))", "\(s.newPairKey!)"]
        let secrets = [Hex.string(s.control.c2h.bytes), Hex.string(s.control.h2c.bytes),
                       Hex.string(s.newPairKey!.bytes), s.pairingCode!.digits]
        for text in rendered { for secret in secrets { #expect(!text.contains(secret)) } }
        #expect(SecretBytes([1, 2, 3]).description == "<redacted>")
    }

    @Test func sealedMessageRoundTripsThroughMessageAPI() throws {
        let s = try schedule(paired: true)
        var sealer = RecordSealer(key: s.control.c2h, maxPayload: ProtocolConstants.maxControlPayload)
        var decoder = RecordDecoder(key: s.control.c2h, connection: .control)
        let messages: [Message] = [.ping(Ping(seq: 1, senderTimeUs: 2)), .bye(.normal), .releaseAll(.focusLost),
                                   .keyframeRequest(.decodeError)]
        for m in messages { decoder.append(try m.sealed(using: &sealer)) }
        for m in messages { #expect(try decoder.nextMessage() == m) }
    }

    @Test func unknownTypeInsideAuthenticRecordIsSkipped() throws {
        let s = try schedule(paired: true)
        var sealer = RecordSealer(key: s.control.c2h, maxPayload: 65_536)
        var decoder = RecordDecoder(key: s.control.c2h, connection: .control)
        decoder.append(try sealer.seal(type: 0x7f, payload: [1, 2, 3]))
        decoder.append(try Message.bye(.normal).sealed(using: &sealer))
        #expect(try decoder.nextMessage() == .bye(.normal))
    }

    @Test func videoFrameThroughputMicroBenchmark() throws {
        // 80 Mbps at 60 fps is about 167 KB per frame. Seal and open 200 frames of 256 KiB and report the rate.
        let s = try schedule(paired: true)
        let keys = try #require(s.videoKeys(nonce: v.bytes("inputs", "video_nonce")))
        var sealer = RecordSealer(key: keys.h2c, maxPayload: ProtocolConstants.maxVideoPayload)
        var decoder = RecordDecoder(key: keys.h2c, connection: .video)
        let data = [UInt8](repeating: 0xAB, count: 256 * 1024)
        let frame = Message.videoFrame(VideoFrame(frameSeq: 1, captureTimeUs: 1, flags: .keyframe, data: data))
        let n = 200
        let start = DispatchTime.now().uptimeNanoseconds
        var sealedTotal = 0
        for _ in 0..<n {
            let record = try frame.sealed(using: &sealer)
            sealedTotal += record.count
            var offset = 0
            while offset < record.count {  // the receive loop hands over at most 64 KiB at a time
                let end = min(offset + FrameDecoder.maxReadChunk, record.count)
                decoder.append(Array(record[offset..<end]))
                offset = end
            }
            #expect(try decoder.nextMessage() != nil)
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        let mbps = Double(sealedTotal) * 8 / seconds / 1e6
        print("crypto micro-benchmark: seal+open \(n) x 256 KiB frames = \(String(format: "%.0f", mbps)) Mbit/s (\(String(format: "%.2f", seconds)) s)")
        #expect(mbps > 400, "sealing and opening must sustain well above 80 Mbit/s")
    }
}

@Suite struct ControlInboundTests {
    @Test func switchesFromPlainToRecordsAfterHello() throws {
        var inbound = ControlInbound()
        inbound.append(Fixtures.bytes("hello"))
        guard case .hello(let hello)? = try inbound.nextMessage() else { Issue.record("no hello"); return }
        #expect(hello.wirePayload == Array(Fixtures.bytes("hello").dropFirst(5)))
        let s = try schedule(paired: true)
        try inbound.enableEncryption(key: s.control.c2h)
        var sealer = RecordSealer(key: s.control.c2h, maxPayload: 65_536)
        inbound.append(try Message.ping(Ping(seq: 3, senderTimeUs: 4)).sealed(using: &sealer))
        #expect(try inbound.nextMessage() == .ping(Ping(seq: 3, senderTimeUs: 4)))
        #expect(inbound.recordCounter == 1)
        // Plain bytes are no longer valid input (here: a zero length header).
        inbound.append([0, 0, 0, 0])
        #expect(throws: CryptoError.self) { try inbound.nextMessage() }
    }

    @Test func plaintextBehindHelloRefusesTheSwitch() throws {
        var inbound = ControlInbound()
        inbound.append(Fixtures.bytes("hello") + [0x20])
        _ = try inbound.nextMessage()
        #expect(inbound.bufferedPlaintextCount == 1)
        #expect(throws: CryptoError.unexpectedPlaintext) {
            try inbound.enableEncryption(key: SecretBytes([UInt8](repeating: 1, count: 32)))
        }
    }
}

@Suite struct CryptoCodecTests {
    @Test func helloTranscriptUsesTheWireBytesNotAReEncoding() throws {
        var wire = Array(Fixtures.bytes("hello").dropFirst(5)) + [9, 9, 9]  // a future field appended to HELLO
        var frame = Fixtures.bytes("hello")
        let newLength = UInt32(wire.count)
        for i in 0..<4 { frame[1 + i] = UInt8(truncatingIfNeeded: newLength >> (8 * UInt32(i))) }
        frame += [9, 9, 9]
        var decoder = FrameDecoder(connection: .control)
        decoder.append(frame)
        guard case .hello(let hello)? = try decoder.nextMessage() else { Issue.record("no hello"); return }
        #expect(hello.transcriptBytes == wire)
        #expect(Message.hello(hello).encodePayload() != wire)  // a re-encoding would drop the extra bytes
        wire.removeLast(3)
        #expect(hello.transcriptBytes != wire)
    }

    @Test func olderHelloYieldsVersionNotAnError() throws {
        // v0 HELLO: no nonce or key. Only protocol_version may be interpreted (PROTOCOL.md 3).
        var w = ByteWriter()
        w.u16(0); w.raw([UInt8](repeating: 1, count: 16)); w.u16(1); w.u16(1); w.u16(1); w.u16(1)
        w.u32(0); w.u8(0)
        guard case .hello(let hello)? = try Message.decode(type: 0x01, payload: w.bytes) else {
            Issue.record("not a hello"); return
        }
        #expect(hello.protocolVersion == 0)
        // Even a one-byte-too-short payload: the version is all that is read.
        guard case .hello(let tiny)? = try Message.decode(type: 0x01, payload: [9, 0]) else {
            Issue.record("not a hello"); return
        }
        #expect(tiny.protocolVersion == 9)
        // A current-version HELLO that is too short stays an error.
        #expect(throws: ProtocolError.payloadTooShort(type: 0x01)) { try Message.decode(type: 0x01, payload: [1, 0, 1]) }
    }

    @Test func unknownKeyModeIsAProtocolError() throws {
        var bytes = Fixtures.bytes("hello_ack")
        bytes[5 + 19] = 3  // key_mode follows version, status, reserved, session_id, video_port and 'Mac mini'
        var decoder = FrameDecoder(connection: .control)
        decoder.append(bytes)
        #expect(throws: ProtocolError.invalidField("key_mode")) { try decoder.nextMessage() }
    }

    @Test func shortVideoHelloIsRejected() {
        var w = ByteWriter()
        w.u16(1); w.u16(1); w.u32(5)  // the v0 layout without video_nonce
        #expect(throws: ProtocolError.payloadTooShort(type: 0x40)) { try Message.decode(type: 0x40, payload: w.bytes) }
    }
}
