/// Any protocol message (docs/PROTOCOL.md section 4).
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case helloAck(HelloAck)
    case streamConfig(StreamConfig)
    case bye(ByeReason)
    case streamPrefs(StreamPrefs)
    case pen(PenBatch)
    case key(KeyEvent)
    case pointerRel(PointerRel)
    case pointerAbs(PointerAbs)
    case scroll(Scroll)
    case penGesture(PenGesture)
    case releaseAll(ReleaseReason)
    case pinch(Pinch)
    case ping(Ping)
    case pong(Pong)
    case stats(Stats)
    case keyframeRequest(KeyframeReason)
    case videoHello(VideoHello)
    case videoFrame(VideoFrame)

    public var type: MessageType {
        switch self {
        case .hello: .hello
        case .helloAck: .helloAck
        case .streamConfig: .streamConfig
        case .bye: .bye
        case .streamPrefs: .streamPrefs
        case .pen: .pen
        case .key: .key
        case .pointerRel: .pointerRel
        case .pointerAbs: .pointerAbs
        case .scroll: .scroll
        case .penGesture: .penGesture
        case .releaseAll: .releaseAll
        case .pinch: .pinch
        case .ping: .ping
        case .pong: .pong
        case .stats: .stats
        case .keyframeRequest: .keyframeRequest
        case .videoHello: .videoHello
        case .videoFrame: .videoFrame
        }
    }

    /// Payload only (no 5-byte header).
    public func encodePayload() -> [UInt8] {
        var w = ByteWriter()
        switch self {
        case .hello(let m): m.write(&w)
        case .helloAck(let m): m.write(&w)
        case .streamConfig(let m): m.write(&w)
        case .bye(let r): w.u8(r.rawValue)
        case .streamPrefs(let m): m.write(&w)
        case .pen(let m): m.write(&w)
        case .key(let m): m.write(&w)
        case .pointerRel(let m): m.write(&w)
        case .pointerAbs(let m): m.write(&w)
        case .scroll(let m): m.write(&w)
        case .penGesture(let m): m.write(&w)
        case .releaseAll(let r): w.u8(r.rawValue)
        case .pinch(let m): m.write(&w)
        case .ping(let m):
            w.u32(m.seq)
            w.u64(m.senderTimeUs)
        case .pong(let m):
            w.u32(m.seq)
            w.u64(m.echoTimeUs)
            w.u64(m.responderTimeUs)
        case .stats(let m):
            w.u32(m.intervalMs)
            w.u32(m.framesReceived)
            w.u32(m.framesDecoded)
            w.u32(m.framesRendered)
            w.u32(m.framesDropped)
            w.u32(m.decodeTimeAvgUs)
            w.u32(m.latencyAvgUs)
            w.u32(m.bytesReceived)
        case .keyframeRequest(let r): w.u8(r.rawValue)
        case .videoHello(let m):
            w.u16(m.protocolVersion)
            w.u16(m.configID)
            w.u32(m.sessionID)
            w.raw(m.videoNonce)
        case .videoFrame(let m): m.write(&w)
        }
        return w.bytes
    }

    /// Connection this message travels on; decides the payload limit.
    public var connection: FrameDecoder.Connection {
        switch self {
        case .videoHello, .videoFrame: .video
        default: .control
        }
    }

    /// Complete frame: type byte, u32 LE length, payload.
    /// Throws instead of producing a frame the peer would reject: payload over the connection limit,
    /// PEN count outside 1...64, or a VIDEO_FRAME that is not a single whole fragment.
    public func encode() throws -> [UInt8] {
        let payload = try checkedPayload()
        var w = ByteWriter()
        w.u8(type.rawValue)
        w.u32(UInt32(payload.count))
        w.raw(payload)
        return w.bytes
    }

    /// The validated payload shared by the plain frame (`encode`) and the sealed record (`sealed`).
    func checkedPayload() throws -> [UInt8] {
        switch self {
        case .pen(let m):
            guard (1...ProtocolConstants.penMaxSamples).contains(m.samples.count) else {
                throw ProtocolError.invalidField("count")
            }
            for (a, b) in zip(m.samples, m.samples.dropFirst()) where b.dtUs < a.dtUs {
                throw ProtocolError.decreasingSampleTime
            }
        case .videoFrame(let m):
            guard m.fragmentIndex == 0, m.fragmentCount == 1, Int(m.frameSize) == m.data.count else {
                throw ProtocolError.invalidField("video fragment")
            }
        default: break
        }
        let payload = encodePayload()
        let limit = connection.maxPayload
        guard payload.count <= limit else {
            throw ProtocolError.payloadTooLarge(length: UInt32(clamping: payload.count), limit: limit)
        }
        return payload
    }

    /// Decodes one payload. Returns nil for an unknown type (skip it, PROTOCOL.md 2).
    /// Throws `ProtocolError` for a short payload or an invalid field value.
    public static func decode(type rawType: UInt8, payload: [UInt8]) throws -> Message? {
        guard let type = MessageType(rawValue: rawType) else { return nil }
        var r = ByteReader(payload, type: rawType)
        switch type {
        case .hello:
            var hello = try Hello.read(&r)
            hello.wirePayload = payload
            return .hello(hello)
        case .helloAck: return .helloAck(try HelloAck.read(&r))
        case .streamConfig: return .streamConfig(try StreamConfig.read(&r))
        case .bye: return .bye(ByeReason(rawValue: try r.u8()))
        case .streamPrefs: return .streamPrefs(try StreamPrefs.read(&r))
        case .pen: return .pen(try PenBatch.read(&r))
        case .key: return .key(try KeyEvent.read(&r))
        case .pointerRel: return .pointerRel(try PointerRel.read(&r))
        case .pointerAbs: return .pointerAbs(try PointerAbs.read(&r))
        case .scroll: return .scroll(try Scroll.read(&r))
        case .penGesture: return .penGesture(try PenGesture.read(&r))
        case .releaseAll: return .releaseAll(ReleaseReason(rawValue: try r.u8()))
        case .pinch: return .pinch(try Pinch.read(&r))
        case .ping: return .ping(Ping(seq: try r.u32(), senderTimeUs: try r.u64()))
        case .pong: return .pong(Pong(seq: try r.u32(), echoTimeUs: try r.u64(), responderTimeUs: try r.u64()))
        case .stats:
            return .stats(Stats(intervalMs: try r.u32(), framesReceived: try r.u32(), framesDecoded: try r.u32(),
                                framesRendered: try r.u32(), framesDropped: try r.u32(),
                                decodeTimeAvgUs: try r.u32(), latencyAvgUs: try r.u32(),
                                bytesReceived: try r.u32()))
        case .keyframeRequest: return .keyframeRequest(KeyframeReason(rawValue: try r.u8()))
        case .videoHello:
            return .videoHello(VideoHello(protocolVersion: try r.u16(), configID: try r.u16(),
                                          sessionID: try r.u32(),
                                          videoNonce: try r.raw(ProtocolConstants.nonceSize)))
        case .videoFrame: return .videoFrame(try VideoFrame.read(&r))
        }
    }
}
