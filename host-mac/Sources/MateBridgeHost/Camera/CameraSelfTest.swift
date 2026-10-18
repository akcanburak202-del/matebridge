import CoreMedia
import CoreVideo
import Darwin
import Foundation
import MateBridgeCore
import os
import VideoToolbox

/// `--camera-selftest` (T-354): the tablet camera path end to end on loopback, command line only. No window, no camera
/// access, no OBS and no tablet: a fake tablet speaks the real protocol to a real `CameraConnectionService`
/// (plain `CAM_HELLO`, ACK, AES-GCM records under keys of a test session, a proof `PING`, `CODEC_CONFIG` and H.264 frames
/// produced by VideoToolbox's own encoder), and the decoded frames land in a counting sink instead of the OBS camera.
/// Exit code 0 only when every check passed. Frame content is synthetic.
public enum CameraSelfTest {
    public static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print((ok ? "ok   " : "FAIL ") + what)
            if !ok { failures += 1 }
        }

        // The test session: fixed secrets, the real key schedule.
        guard let schedule = try? SessionKeySchedule.derive(
            ecdh: [UInt8](repeating: 7, count: 32), pairKey: SecretBytes([UInt8](repeating: 9, count: 32)),
            helloPayload: [1, 2, 3], ackPayload: [4, 5, 6]) else {
            print("FAIL key schedule")
            return 1
        }
        let sessionID: UInt32 = 77
        let camID: UInt16 = 5

        // Encoded test stream: 60 frames of 1280x720 (the decoder output is scaled up to 1920x1080).
        let stream = TestEncoder.encode(width: 1280, height: 720, frames: 60, keyframeEvery: 30)
        check(!stream.config.isEmpty && stream.frames.count == 60, "encoder produced SPS/PPS and 60 frames")
        guard !stream.config.isEmpty, stream.frames.count == 60 else { return 1 }

        let service = CameraConnectionService()
        let received = OSAllocatedUnfairLock<[(Int, Int, OSType)]>(initialState: [])
        let activeEvents = OSAllocatedUnfairLock<[Bool]>(initialState: [])
        service.sink = { frame in
            let w = CVPixelBufferGetWidth(frame.value), h = CVPixelBufferGetHeight(frame.value)
            let format = CVPixelBufferGetPixelFormatType(frame.value)
            received.withLock { $0.append((w, h, format)) }
        }
        service.onActive = { active in activeEvents.withLock { $0.append(active) } }
        guard let port = service.open(sessionID: sessionID, camID: camID, controlPeer: "127.0.0.1", keys: { sid, client, host in
            sid == sessionID ? schedule.cameraKeys(clientNonce: client, hostNonce: host) : nil
        }) else {
            print("FAIL listener")
            return 1
        }
        print("listening on port \(port)")

        // 1. A wrong cam_id is rejected (plain REJECTED, then closed).
        do {
            let c = FakeTablet(port: port)
            let ack = c?.hello(sessionID: sessionID, camID: camID &+ 1)
            check(ack?.status == CamHelloStatus.rejected && ack?.hostNonce == [UInt8](repeating: 0, count: 16), "wrong cam_id gets REJECTED with a zero nonce")
            c?.close()
        }

        // 2. A frame before the proof ends the connection (and does not decode anything).
        do {
            let c = FakeTablet(port: port)
            _ = c?.hello(sessionID: sessionID, camID: camID)
            if let c, let keys = c.keys(schedule) {
                var sealer = RecordSealer(key: keys.c2h, maxPayload: ProtocolConstants.maxCameraPayload)
                let early = try? Message.camFrame(CamFrame(frameSeq: 0, captureTimeUs: 0, flags: .keyframe, data: stream.frames[0].data))
                    .sealed(using: &sealer)
                c.send(early ?? [])
                check(c.waitForClose(seconds: 3), "a CAM_FRAME before the proof closes only that connection")
            } else {
                check(false, "handshake for the early-frame case")
            }
            c?.close()
        }
        check(received.withLock { $0.isEmpty }, "nothing was written to the sink so far")

        // 3. The real stream.
        guard let tablet = FakeTablet(port: port), tablet.hello(sessionID: sessionID, camID: camID)?.isOK == true,
              let keys = tablet.keys(schedule) else {
            print("FAIL main handshake")
            service.close()
            return 1
        }
        var sealer = RecordSealer(key: keys.c2h, maxPayload: ProtocolConstants.maxCameraPayload)
        var inbound = RecordDecoder(key: keys.h2c, connection: .camera)
        func send(_ m: Message) {
            if let record = try? m.sealed(using: &sealer) { tablet.send(record) }
        }
        send(.ping(Ping(seq: 1, senderTimeUs: 1)))  // the proof
        // The host asks for a keyframe (STARTUP) right after the proof.
        var request: CamKeyframeReason?
        let deadline = Date().addingTimeInterval(3)
        while request == nil, Date() < deadline {
            let bytes = tablet.read(timeout: 0.2)
            if !bytes.isEmpty { inbound.append(bytes) }
            if case .camKeyframeRequest(let r)? = try? inbound.nextMessage() { request = r }
        }
        check(request == .startup, "host sends CAM_KEYFRAME_REQUEST(STARTUP) after the proof")
        check(activeEvents.withLock { $0 == [true] }, "the proven connection became the active one")

        var seq: UInt32 = 0
        send(.camFrame(CamFrame(frameSeq: seq, captureTimeUs: 0, flags: .codecConfig, data: stream.config)))
        seq += 1
        // 30 fps pacing, like a camera; the host must keep up without dropping.
        let start = Date()
        for (i, frame) in stream.frames.enumerated() {
            send(.camFrame(CamFrame(frameSeq: seq, captureTimeUs: UInt64(i) * 33_333, flags: frame.keyframe ? .keyframe : [], data: frame.data)))
            seq += 1
            let due = start.addingTimeInterval(Double(i + 1) / 30)
            let wait = due.timeIntervalSinceNow
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        let until = Date().addingTimeInterval(3)
        while received.withLock({ $0.count }) < stream.frames.count, Date() < until { Thread.sleep(forTimeInterval: 0.05) }
        let frames = received.withLock { $0 }
        print("sink received \(frames.count) of \(stream.frames.count) frames")
        check(frames.count >= stream.frames.count - 2, "nearly every frame decoded at 30 fps (at most 2 lost)")
        check(frames.allSatisfy { $0.0 == 1920 && $0.1 == 1080 && $0.2 == kCVPixelFormatType_32BGRA }, "every frame is 1920x1080 BGRA")

        // 4. A burst larger than the queue: stale frames are dropped, a keyframe is requested, the stream recovers.
        let before = received.withLock { $0.count }
        for i in 0..<20 {  // P frames only, no pacing
            send(.camFrame(CamFrame(frameSeq: seq, captureTimeUs: UInt64(1_000_000 + i * 33_333), flags: [], data: stream.frames[1 + (i % 28)].data)))
            seq += 1
        }
        var sawRequest = false
        let burstEnd = Date().addingTimeInterval(2)
        while Date() < burstEnd {
            let bytes = tablet.read(timeout: 0.1)
            if !bytes.isEmpty { inbound.append(bytes) }
            while let m = try? inbound.nextMessage() { if case .camKeyframeRequest = m { sawRequest = true } }
        }
        print("burst: \(received.withLock { $0.count } - before) frames written, keyframe request seen: \(sawRequest)")

        // 5. Recovery on a keyframe, then the connection closes with the session.
        send(.camFrame(CamFrame(frameSeq: seq, captureTimeUs: 2_000_000, flags: .codecConfig, data: stream.config)))
        seq += 1
        send(.camFrame(CamFrame(frameSeq: seq, captureTimeUs: 2_000_001, flags: .keyframe, data: stream.frames[0].data)))
        seq += 1
        let recoverUntil = Date().addingTimeInterval(3)
        let beforeRecovery = received.withLock { $0.count }
        while received.withLock({ $0.count }) <= beforeRecovery, Date() < recoverUntil { Thread.sleep(forTimeInterval: 0.05) }
        check(received.withLock { $0.count } > beforeRecovery, "a keyframe after the burst decodes again")

        service.close()
        check(tablet.waitForClose(seconds: 3), "closing the service closes the camera connection")
        check(activeEvents.withLock { $0.last == false }, "the active connection reported its end")
        check(!service.isRunning, "the service is fully stopped")
        tablet.close()

        print(failures == 0 ? "camera selftest: all checks passed" : "camera selftest: \(failures) check(s) FAILED")
        return failures == 0 ? 0 : 1
    }
}

// MARK: - Fake tablet (test side only, blocking sockets)

private final class FakeTablet {
    private let fd: Int32
    private var clientNonce = (0..<16).map { _ in UInt8.random(in: 0...255) }
    private var hostNonce: [UInt8] = []

    init?(port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); return nil }
        self.fd = fd
    }

    func close() { Darwin.close(fd) }

    func send(_ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n <= 0 { return }
            offset += n
        }
    }

    /// Reads what is available within `timeout` seconds; empty on timeout or close.
    func read(timeout: Double) -> [UInt8] {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, Int32(timeout * 1000)) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let n = Darwin.read(fd, &buffer, buffer.count)
        return n > 0 ? Array(buffer[0..<n]) : []
    }

    func waitForClose(seconds: Double) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            var b = [UInt8](repeating: 0, count: 4096)
            if Darwin.read(fd, &b, b.count) <= 0 { return true }
        }
        return false
    }

    /// Sends the plain CAM_HELLO and reads the plain CAM_HELLO_ACK.
    func hello(sessionID: UInt32, camID: UInt16) -> CamHelloAck? {
        guard let bytes = try? Message.camHello(CamHello(sessionID: sessionID, camID: camID, clientNonce: clientNonce)).encode() else { return nil }
        send(bytes)
        var decoder = FrameDecoder(connection: .camera)
        let end = Date().addingTimeInterval(3)
        while Date() < end {
            let got = read(timeout: 0.2)
            if !got.isEmpty { decoder.append(got) }
            if case .camHelloAck(let ack)? = try? decoder.nextMessage() {
                hostNonce = ack.hostNonce
                return ack
            }
        }
        return nil
    }

    func keys(_ schedule: SessionKeySchedule) -> CameraKeys? {
        schedule.cameraKeys(clientNonce: clientNonce, hostNonce: hostNonce)
    }
}

// MARK: - Test stream (VideoToolbox H.264 encoder, synthetic frames)

private enum TestEncoder {
    struct EncodedFrame {
        var data: [UInt8]
        var keyframe: Bool
    }

    /// SPS+PPS in Annex-B, and `frames` Annex-B access units, from a real hardware/software H.264 encode.
    static func encode(width: Int, height: Int, frames count: Int, keyframeEvery: Int) -> (config: [UInt8], frames: [EncodedFrame]) {
        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var config: [UInt8] = []
            var frames: [Int: EncodedFrame] = [:]
        }
        let collector = Collector()
        var sessionOut: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &sessionOut) == 0,
              let session = sessionOut else { return ([], []) }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 4_000_000 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeEvery as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)
        for i in 0..<count {
            var pbOut: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pbOut)
            guard let pb = pbOut else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                for y in 0..<height {
                    let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width {
                        row[x * 4] = UInt8(truncatingIfNeeded: x + i * 4)
                        row[x * 4 + 1] = UInt8(truncatingIfNeeded: y + i * 2)
                        row[x * 4 + 2] = UInt8(truncatingIfNeeded: (x ^ y) + i)
                        row[x * 4 + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 30),
                                            frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
                guard status == 0, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == 0,
                      let pointer else { return }
                let avcc = Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: length))
                var annexB: [UInt8] = []
                var offset = 0
                while offset + 4 <= avcc.count {
                    let n = Int(avcc[offset]) << 24 | Int(avcc[offset + 1]) << 16 | Int(avcc[offset + 2]) << 8 | Int(avcc[offset + 3])
                    offset += 4
                    guard n > 0, offset + n <= avcc.count else { break }
                    annexB += [0, 0, 0, 1]
                    annexB += avcc[offset..<offset + n]
                    offset += n
                }
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
                collector.lock.lock()
                collector.frames[i] = EncodedFrame(data: annexB, keyframe: !notSync)
                if collector.config.isEmpty, let fd = CMSampleBufferGetFormatDescription(sample) {
                    var sets: [[UInt8]] = []
                    for index in 0..<2 {
                        var ptr: UnsafePointer<UInt8>?
                        var size = 0
                        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: index, parameterSetPointerOut: &ptr,
                                                                              parameterSetSizeOut: &size, parameterSetCountOut: nil,
                                                                              nalUnitHeaderLengthOut: nil) == 0, let ptr {
                            sets.append(Array(UnsafeBufferPointer(start: ptr, count: size)))
                        }
                    }
                    collector.config = sets.flatMap { [0, 0, 0, 1] + $0 }
                }
                collector.lock.unlock()
            }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        collector.lock.lock()
        defer { collector.lock.unlock() }
        let ordered = (0..<count).compactMap { collector.frames[$0] }
        return (collector.config, ordered)
    }
}
