/// Any protocol message (docs/PROTOCOL.md section 4).
public enum Message: Equatable, Sendable {
    case hello(Hello)
    case helloAck(HelloAck)
    case streamConfig(StreamConfig)
    case bye(ByeReason)
    case streamPrefs(StreamPrefs)
    case clipboard(Clipboard)
    case displayRate(DisplayRate)
    case settingsOpen(SettingsOpen)
    case filesInfo(FilesInfo)
    case filesNet(FilesNet)
    case cursorPrefs(CursorPrefs)
    case cursorShape(CursorShape)
    case cursorState(CursorState)
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
    /// `view` is the optional trailing byte (decision 0034); nil = absent on the wire = both streams.
    case keyframeRequest(KeyframeReason, view: KeyframeView? = nil)
    case audioPrefs(AudioPrefs)
    case audioConfig(AudioConfig)
    case audioFrame(AudioFrame)
    case videoHello(VideoHello)
    case videoFrame(VideoFrame)
    case filesHello(FilesHello)
    case filesHelloAck(FilesHelloAck)
    case filesData(FilesData)

    public var type: MessageType {
        switch self {
        case .hello: .hello
        case .helloAck: .helloAck
        case .streamConfig: .streamConfig
        case .bye: .bye
        case .streamPrefs: .streamPrefs
        case .clipboard: .clipboard
        case .displayRate: .displayRate
        case .settingsOpen: .settingsOpen
        case .filesInfo: .filesInfo
        case .filesNet: .filesNet
        case .cursorPrefs: .cursorPrefs
        case .cursorShape: .cursorShape
        case .cursorState: .cursorState
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
        case .audioPrefs: .audioPrefs
        case .audioConfig: .audioConfig
        case .audioFrame: .audioFrame
        case .videoHello: .videoHello
        case .videoFrame: .videoFrame
        case .filesHello: .filesHello
        case .filesHelloAck: .filesHelloAck
        case .filesData: .filesData
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
        case .clipboard(let m): m.write(&w)
        case .displayRate(let m): m.write(&w)
        case .settingsOpen(let m): m.write(&w)
        case .filesInfo(let m): m.write(&w)
        case .filesNet(let m): m.write(&w)
        case .cursorPrefs(let m): m.write(&w)
        case .cursorShape(let m): m.write(&w)
        case .cursorState(let m): m.write(&w)
        case .pen(let m): m.write(&w)
        case .key(let m): m.write(&w)
        case .pointerRel(let m): m.write(&w)
        case .pointerAbs(let m): m.write(&w)
        case .scroll(let m): m.write(&w)
        case .penGesture(let m): m.write(&w)
        case .releaseAll(let r): w.u8(r.rawValue)
        case .pinch(let m): m.write(&w)
        case .ping(let m): m.write(&w)
        case .pong(let m): m.write(&w)
        case .stats(let m): m.write(&w)
        case .keyframeRequest(let r, let view):
            w.u8(r.rawValue)
            if let view { w.u8(view.rawValue) }
        case .audioPrefs(let m): m.write(&w)
        case .audioConfig(let m): m.write(&w)
        case .audioFrame(let m): m.write(&w)
        case .videoHello(let m): m.write(&w)
        case .videoFrame(let m): m.write(&w)
        case .filesHello(let m): m.write(&w)
        case .filesHelloAck(let m): m.write(&w)
        case .filesData(let m): m.write(&w)
        }
        return w.bytes
    }

    /// Connection this message travels on; decides the payload limit.
    public var connection: FrameDecoder.Connection {
        switch self {
        case .videoHello, .videoFrame: .video
        case .filesHello, .filesHelloAck, .filesData: .files
        default: .control
        }
    }

    /// Complete frame: type byte, u32 LE length, payload.
    /// Throws instead of producing a frame the peer would reject: payload over the connection limit,
    /// PEN count outside 1...64, AUDIO_FRAME frame_count outside 1...960 or data over 65535 bytes,
    /// a VIDEO_FRAME that is not a single whole fragment, or a FILES_DATA with 0 or more than 65 534 bytes,
    /// or a CURSOR_SHAPE with 0 or more than 61 440 bytes of image.
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
        case .clipboard(let m):
            guard m.data.count <= ProtocolConstants.clipboardMaxBytes else { throw ProtocolError.invalidField("length") }
        case .audioFrame(let m):
            guard (1...ProtocolConstants.audioMaxFrames).contains(Int(m.frameCount)) else {
                throw ProtocolError.invalidField("frame_count")
            }
            guard m.data.count <= Int(UInt16.max) else { throw ProtocolError.invalidField("data_len") }
        case .videoFrame(let m):
            guard m.fragmentIndex == 0, m.fragmentCount == 1, Int(m.frameSize) == m.data.count else {
                throw ProtocolError.invalidField("video fragment")
            }
        case .filesData(let m):
            guard (1...ProtocolConstants.filesDataMax).contains(m.data.count) else {
                throw ProtocolError.invalidField("size")
            }
        case .cursorShape(let m):
            guard (1...CursorShape.maxDataBytes).contains(m.data.count) else {
                throw ProtocolError.invalidField("data_len")
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
        case .clipboard: return .clipboard(try Clipboard.read(&r))
        case .displayRate: return .displayRate(try DisplayRate.read(&r))
        case .settingsOpen: return .settingsOpen(try SettingsOpen.read(&r))
        case .filesInfo: return .filesInfo(try FilesInfo.read(&r))
        case .filesNet: return .filesNet(try FilesNet.read(&r))
        case .cursorPrefs: return .cursorPrefs(try CursorPrefs.read(&r))
        case .cursorShape: return .cursorShape(try CursorShape.read(&r))
        case .cursorState: return .cursorState(try CursorState.read(&r))
        case .pen: return .pen(try PenBatch.read(&r))
        case .key: return .key(try KeyEvent.read(&r))
        case .pointerRel: return .pointerRel(try PointerRel.read(&r))
        case .pointerAbs: return .pointerAbs(try PointerAbs.read(&r))
        case .scroll: return .scroll(try Scroll.read(&r))
        case .penGesture: return .penGesture(try PenGesture.read(&r))
        case .releaseAll: return .releaseAll(ReleaseReason(rawValue: try r.u8()))
        case .pinch: return .pinch(try Pinch.read(&r))
        case .ping: return .ping(try Ping.read(&r))
        case .pong: return .pong(try Pong.read(&r))
        case .stats: return .stats(try Stats.read(&r))
        case .keyframeRequest:
            let reason = KeyframeReason(rawValue: try r.u8())
            // Optional trailing view (decision 0034); a longer payload's extra bytes are ignored.
            return .keyframeRequest(reason, view: r.remaining > 0 ? KeyframeView(wire: try r.u8()) : nil)
        case .audioPrefs: return .audioPrefs(try AudioPrefs.read(&r))
        case .audioConfig: return .audioConfig(try AudioConfig.read(&r))
        case .audioFrame: return .audioFrame(try AudioFrame.read(&r))
        case .videoHello: return .videoHello(try VideoHello.read(&r))
        case .videoFrame: return .videoFrame(try VideoFrame.read(&r))
        case .filesHello: return .filesHello(try FilesHello.read(&r))
        case .filesHelloAck: return .filesHelloAck(try FilesHelloAck.read(&r))
        case .filesData: return .filesData(try FilesData.read(&r))
        }
    }
}
