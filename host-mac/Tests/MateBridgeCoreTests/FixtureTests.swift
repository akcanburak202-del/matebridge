import Testing
@testable import MateBridgeCore

private let deviceA = DeviceID(bytes: Array(Array(repeating: [UInt8](arrayLiteral: 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef), count: 2).joined()))!
private let deviceB = DeviceID(bytes: Array(0...15))!

/// Public keys of the vector private keys (`crypto_vectors.json` inputs): 65-byte uncompressed points.
private let clientPub = Hex.bytes("043b2e3be924f7393ba036956d4f154be45d37e6c02baecfc991a3c6ae4213629e7ab47261459f5823e7e72769597493bc607eb317d9ef1ca4ddb85f3cc2a35538")
private let hostPub = Hex.bytes("04a417215b2ffac23f26ff2b85372f155fc16a7aa6b79ffbf4a37e5bb82cd72453761d437b3fe609bf5d0cefdfd95463724938ae81a3f04c8dbc2af6be0cac5efb")

private func pen(_ dt: UInt32, _ x: UInt16, _ y: UInt16, _ p: UInt16, _ tx: Int16, _ ty: Int16, _ f: PenFlags) -> PenSample {
    PenSample(dtUs: dt, x: x, y: y, pressure: p, tiltX: tx, tiltY: ty, flags: f)
}

/// Hand-written expectations, copied from the comments in each `.hex` file.
private let validFixtures: [String: Message] = [
    "hello": .hello(Hello(deviceID: deviceA, screenWidthPx: 2800, screenHeightPx: 1840, densityDpi: 360,
                          maxRefreshHz: 144, capabilities: Capabilities(rawValue: 255), deviceName: "MatePad Pro",
                          clientNonce: Array(0xc0...0xcf), clientEphPub: clientPub)),
    "hello_utf8_name": .hello(Hello(deviceID: deviceB, screenWidthPx: 2800, screenHeightPx: 1840, densityDpi: 360,
                                    maxRefreshHz: 60, capabilities: [.pen, .keyboard, .decodeH264],
                                    deviceName: "Çizim Tableti ğüşöı", clientNonce: Array(0xc0...0xcf),
                                    clientEphPub: clientPub)),
    "hello_ack": .helloAck(HelloAck(status: .accepted, sessionID: 2_712_847_316, videoPort: 47001, hostName: "Mac mini",
                                    keyMode: .paired, hostID: Array(0x30...0x3f), hostNonce: Array(0xe0...0xef),
                                    hostEphPub: hostPub)),
    "hello_ack_pending": .helloAck(HelloAck(status: .pendingApproval, sessionID: 0, videoPort: 0, hostName: "Mac mini",
                                            keyMode: .pairing, hostID: Array(0x30...0x3f),
                                            hostNonce: Array(0xe0...0xef), hostEphPub: hostPub)),
    "hello_ack_busy": .helloAck(HelloAck(status: .busy, sessionID: 0, videoPort: 0, hostName: "")),
    "stream_config": .streamConfig(StreamConfig(configID: 1, codec: .hevc, widthPx: 2800, heightPx: 1840,
                                                widthPt: 1400, heightPt: 920, fps: 60, bitrateKbps: 50000,
                                                colorPrimaries: 1, transfer: 13, matrix: 1, fullRange: true)),
    "bye": .bye(.normal),
    "stream_prefs": .streamPrefs(StreamPrefs(fps: 120, scalePermille: 750)),
    "clipboard_text": .clipboard(Clipboard.text(seq: 3, "Merhaba ğüşıöç — kopyala")),
    "clipboard_empty": .clipboard(Clipboard.empty(seq: 4)),
    "pen_hover_to_contact": .pen(PenBatch(tool: .pen, baseTimeUs: 1_127_411_618_000, samples: [
        pen(0, 22364, 12738, 0, 3000, 2500, .inRange),
        pen(3000, 22380, 12750, 288, 3000, 2500, [.inRange, .contact, .strokeStart]),
        pen(6000, 22410, 12771, 32768, 2980, 2490, [.inRange, .contact]),
        pen(9000, 22430, 12790, 0, 2980, 2490, .inRange),
    ])),
    "pen_leave": .pen(PenBatch(tool: .pen, baseTimeUs: 1_127_411_700_000, samples: [
        pen(0, 22430, 12790, 0, 0, 0, []),
    ])),
    "pen_eraser": .pen(PenBatch(tool: .eraser, baseTimeUs: 1_127_411_800_000, samples: [
        pen(0, 1000, 2000, 65535, -32767, 0, [.inRange, .contact, .button, .strokeStart]),
    ])),
    "pen_extremes": .pen(PenBatch(tool: .pen, baseTimeUs: 0, samples: [
        pen(0, 65535, 65535, 65535, 32767, -32767, [.inRange, .contact]),
        pen(4_294_967_295, 65535, 65535, 65535, -32767, 32767, [.inRange, .contact]),
    ])),
    "pen_gesture": .penGesture(PenGesture(timeUs: 1_127_465_515_000, gesture: .doubleTap)),
    "key_down": .key(KeyEvent(timeUs: 1_127_463_498_000, scanCode: 30, androidKeyCode: 29, action: .down, capsLockOn: false)),
    "key_up_caps": .key(KeyEvent(timeUs: 1_127_463_600_000, scanCode: 58, androidKeyCode: 115, action: .up, capsLockOn: true)),
    "key_no_scan": .key(KeyEvent(timeUs: 1_127_463_700_000, scanCode: 0, androidKeyCode: 85, action: .down, capsLockOn: false)),
    "pointer_rel": .pointerRel(PointerRel(timeUs: 1_127_500_489_000, dx: 2.5, dy: -1.25, buttons: .left)),
    "pointer_abs": .pointerAbs(PointerAbs(timeUs: 1_127_500_500_000, x: 32768, y: 32768, buttons: .left, source: .touch)),
    "scroll_began": .scroll(Scroll(timeUs: 1_127_500_590_000, dx: 0, dy: 0, phase: .began)),
    "scroll": .scroll(Scroll(timeUs: 1_127_500_600_000, dx: 0, dy: 12.5, phase: .changed)),
    "scroll_ended": .scroll(Scroll(timeUs: 1_127_500_700_000, dx: 0, dy: 0, phase: .ended)),
    "pinch_began": .pinch(Pinch(timeUs: 1_127_500_800_000, scale: 0, x: 24576, y: 32768, phase: .began, source: .touch)),
    "pinch": .pinch(Pinch(timeUs: 1_127_500_816_000, scale: 0.05, x: 24576, y: 32768, phase: .changed, source: .touch)),
    "pinch_ended": .pinch(Pinch(timeUs: 1_127_500_900_000, scale: 0, x: 0, y: 0, phase: .ended, source: .touchpad)),
    "release_all": .releaseAll(.background),
    "ping": .ping(Ping(seq: 7, senderTimeUs: 1_127_500_700_000)),
    "pong": .pong(Pong(seq: 7, echoTimeUs: 1_127_500_700_000, responderTimeUs: 98_765_432_100)),
    "stats": .stats(Stats(intervalMs: 1000, framesReceived: 60, framesDecoded: 60, framesRendered: 59,
                          framesDropped: 1, decodeTimeAvgUs: 4200, latencyAvgUs: 23000, bytesReceived: 6_250_000)),
    "keyframe_request": .keyframeRequest(.decodeError),
    "video_hello": .videoHello(VideoHello(configID: 1, sessionID: 2_712_847_316,
                                          videoNonce: Array((0...15).reversed()))),
    "video_frame": .videoFrame(VideoFrame(frameSeq: 1, captureTimeUs: 98_765_000_000, flags: .keyframe,
                                          data: [0, 0, 0, 1, 0x26, 0x01, 0x0a, 0xf0])),
    "video_frame_config": .videoFrame(VideoFrame(frameSeq: 0, captureTimeUs: 98_764_990_000, flags: .codecConfig,
                                                 data: [0, 0, 0, 1, 0x40, 0x01])),
]

private let invalidFixtures: [String: ProtocolError] = [
    "invalid_key_short": .payloadTooShort(type: 0x11),
    "invalid_pen_count_zero": .invalidField("count"),
]

private let skippedFixtures: Set<String> = ["unknown_type"]

private func connection(for message: Message) -> FrameDecoder.Connection {
    switch message.type {
    case .videoFrame, .videoHello: .video
    default: .control
    }
}

@Suite struct FixtureTests {
    @Test func everyFixtureFileHasATestCase() {
        let covered = Set(validFixtures.keys).union(invalidFixtures.keys).union(skippedFixtures)
        #expect(Fixtures.allNames() == covered)
    }

    @Test(arguments: validFixtures.keys.sorted())
    func decodesToExpectedValue(name: String) throws {
        let bytes = Fixtures.bytes(name)
        let expected = validFixtures[name]!
        var decoder = FrameDecoder(connection: connection(for: expected))
        decoder.append(bytes)
        #expect(try decoder.nextMessage() == expected)
        #expect(try decoder.nextMessage() == nil)
        #expect(decoder.bufferedCount == 0)
    }

    @Test(arguments: validFixtures.keys.sorted())
    func encodesToIdenticalBytes(name: String) throws {
        #expect(try validFixtures[name]!.encode() == Fixtures.bytes(name))
    }

    @Test(arguments: invalidFixtures.keys.sorted())
    func invalidFixturesAreRejected(name: String) {
        var decoder = FrameDecoder(connection: .control)
        decoder.append(Fixtures.bytes(name))
        #expect(throws: invalidFixtures[name]!) { try decoder.nextMessage() }
        // The decoder stays failed.
        #expect(throws: ProtocolError.decoderFailed) { try decoder.nextMessage() }
    }

    @Test func unknownTypeIsSkippedAndStreamContinues() throws {
        let ping = validFixtures["ping"]!
        var decoder = FrameDecoder(connection: .control)
        decoder.append(Fixtures.bytes("unknown_type") + Fixtures.bytes("ping"))
        #expect(try decoder.nextMessage() == ping)
        #expect(try decoder.nextMessage() == nil)

        var alone = FrameDecoder(connection: .control)
        alone.append(Fixtures.bytes("unknown_type"))
        #expect(try alone.nextMessage() == nil)
        #expect(alone.bufferedCount == 0)
    }

    @Test(arguments: validFixtures.keys.sorted())
    func byteAtATimeMatches(name: String) throws {
        let expected = validFixtures[name]!
        var decoder = FrameDecoder(connection: connection(for: expected))
        var out: [Message] = []
        for b in Fixtures.bytes(name) {
            decoder.append([b])
            while let m = try decoder.nextMessage() { out.append(m) }
        }
        #expect(out == [expected])
    }

    @Test func randomChunksOfAllFixturesMatch() throws {
        let names = validFixtures.keys.sorted().filter { connection(for: validFixtures[$0]!) == .control }
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<50 {
            var stream: [UInt8] = []
            var expected: [Message] = []
            for _ in 0..<10 {
                let name = names[Int(rng.next() % UInt64(names.count))]
                stream += Fixtures.bytes(name)
                expected.append(validFixtures[name]!)
            }
            var decoder = FrameDecoder(connection: .control)
            var out: [Message] = []
            var i = 0
            while i < stream.count {
                let n = min(1 + Int(rng.next() % 40), stream.count - i)
                decoder.append(Array(stream[i..<i + n]))
                i += n
                while let m = try decoder.nextMessage() { out.append(m) }
            }
            #expect(out == expected)
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
