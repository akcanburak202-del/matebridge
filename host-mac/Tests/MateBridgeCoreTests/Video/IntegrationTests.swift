import XCTest
@testable import MateBridgeCore

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func hello(w: UInt16 = 2800, h: UInt16 = 1840, hz: UInt16 = 144) -> Hello {
    Hello(deviceID: device(1), screenWidthPx: w, screenHeightPx: h, densityDpi: 360, maxRefreshHz: hz,
          capabilities: [.pen], deviceName: "Pad")
}

final class StreamSettingsTests: XCTestCase {
    func testTabletNativeSizeHiDPIHevc() {
        let s = VideoSettings.forTablet(hello())
        XCTAssertEqual([s.widthPx, s.heightPx, s.widthPt, s.heightPt], [2800, 1840, 1400, 920])
        XCTAssertEqual(s.codec, .hevc)
        XCTAssertEqual(s.fps, 60, "refresh rate is capped at 60")
        let config = s.streamConfig(configID: 1)
        XCTAssertEqual(config.codec, .hevc, "STREAM_CONFIG announces HEVC, not the H.264 placeholder")
        XCTAssertEqual(config.widthPx, 2800)
        XCTAssertEqual(config.bitrateKbps, 30_000)
    }

    func testOtherSizeAndLowRefresh() {
        let s = VideoSettings.forTablet(hello(w: 1920, h: 1200, hz: 30))
        XCTAssertEqual([s.widthPx, s.heightPx, s.widthPt, s.heightPt, s.fps], [1920, 1200, 960, 600, 30])
        XCTAssertEqual(VideoSettings.forTablet(hello(hz: 0)).fps, 60)
        XCTAssertEqual(VideoSettings.forTablet(hello(hz: 24)).fps, 24, "fps = min(tablet Hz, 60)")
        XCTAssertEqual(VideoSettings.forTablet(hello(hz: 120)).fps, 60)
    }

    func testGarbageSizeFallsBackToDefault() {
        for (w, h) in [(0, 0), (2801, 1840), (2800, 1), (9000, 1840)] as [(UInt16, UInt16)] {
            let s = VideoSettings.forTablet(hello(w: w, h: h))
            XCTAssertEqual([s.widthPx, s.heightPx], [2800, 1840], "\(w)x\(h)")
        }
    }
}

final class DisplayLeaseTests: XCTestCase {
    private let sec: UInt64 = 1_000_000
    private let s = VideoSettings.tabletDefault

    func testCreateThenGraceThenTeardown() {
        var l = DisplayLease()
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.create(s)])
        XCTAssertTrue(l.tick(now: 100 * sec).isEmpty, "no grace while the session is active")
        l.sessionEnded(now: 100 * sec)
        XCTAssertTrue(l.isInGrace)
        XCTAssertTrue(l.tick(now: 109 * sec).isEmpty)
        XCTAssertEqual(l.tick(now: 110 * sec), [.teardown], "closes exactly after 10 s")
        XCTAssertFalse(l.hasDisplay)
        XCTAssertTrue(l.tick(now: 200 * sec).isEmpty, "teardown happens once")
    }

    func testSameDeviceReturningInGraceReusesDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.reuse])
        XCTAssertFalse(l.isInGrace)
        XCTAssertTrue(l.tick(now: 60 * sec).isEmpty, "reuse cancelled the grace timer")
    }

    func testDifferentDeviceOrSettingsReplacesDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: s), [.teardown, .create(s)])
        l.sessionEnded(now: 0)
        var other = s
        other.widthPx = 1920
        XCTAssertEqual(l.sessionStarted(device: device(2), settings: other), [.teardown, .create(other)])
    }

    func testTakeoverWithoutEndKeepsDisplay() {
        var l = DisplayLease()
        _ = l.sessionStarted(device: device(1), settings: s)
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.reuse])
    }

    func testShutdownAndDisplayLost() {
        var l = DisplayLease()
        XCTAssertTrue(l.shutdown().isEmpty)
        _ = l.sessionStarted(device: device(1), settings: s)
        XCTAssertEqual(l.shutdown(), [.teardown])
        _ = l.sessionStarted(device: device(1), settings: s)
        l.displayLost()
        XCTAssertEqual(l.sessionStarted(device: device(1), settings: s), [.create(s)], "a dead display is recreated")
    }
}

private final class FakeTransport: VideoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var ready: (@Sendable () -> Void)?
    private var completions: [@Sendable (Bool) -> Void] = []
    private(set) var sent: [VideoFrame] = []
    var limit = 2
    var accept = true

    var canSend: Bool { lock.withLock { inFlight < limit } }
    func setReadyHandler(_ handler: (@Sendable () -> Void)?) { lock.withLock { ready = handler } }
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.withLock {
            guard accept, inFlight < limit else { return false }
            inFlight += 1
            sent.append(frame)
            completions.append(completion)
            return true
        }
    }
    var sentCount: Int { lock.withLock { sent.count } }
    /// Completes the oldest outstanding send.
    func complete(_ ok: Bool = true) {
        let (c, r): (@Sendable (Bool) -> Void, (@Sendable () -> Void)?) = lock.withLock {
            inFlight -= 1
            return (completions.removeFirst(), ready)
        }
        c(ok)
        r?()
    }
}

final class VideoSenderTests: XCTestCase {
    private func delta(_ n: UInt8) -> EncodedVideoFrame { .init(flags: [], captureTimeUs: UInt64(n), data: [n]) }
    private func key(_ n: UInt8) -> EncodedVideoFrame { .init(flags: .keyframe, captureTimeUs: UInt64(n), data: [n]) }

    private func waitUntil(_ what: String, timeout: TimeInterval = 2, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(cond(), what)
    }

    func testSequenceStartsAtZeroAndBackpressureCapsInFlightAtTwo() async {
        let transport = FakeTransport()
        let keyframeRequests = LockedCounter()
        let frames = VideoFrameQueue(keyframeNeeded: { keyframeRequests.increment() })
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: {})
        sender.start()

        frames.push(key(1))
        frames.push(delta(2))
        await waitUntil("two frames sent") { transport.sentCount == 2 }
        XCTAssertEqual(transport.sent.map(\.frameSeq), [0, 1])

        // The socket is stuck (2 in flight): the sender must not pull more, the 2-frame queue drops old deltas.
        frames.push(delta(3))
        frames.push(delta(4))
        frames.push(delta(5))
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sentCount, 2, "never more than 2 in flight")
        XCTAssertGreaterThan(keyframeRequests.value, 0, "overflow asks for a keyframe")

        // Delta 3 was dropped and its dependents (4, 5) purged: nothing stale may follow; the keyframe resyncs.
        transport.complete()
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(transport.sentCount, 2, "no dependent delta is sent after the drop")
        frames.push(key(6))
        await waitUntil("keyframe sent after a slot frees") { transport.sentCount == 3 }
        XCTAssertEqual(transport.sent.last?.data, [6])
        XCTAssertEqual(transport.sent.last?.frameSeq, 2, "no gaps in frame_seq")
        await sender.stop()
        XCTAssertEqual(sender.currentCounters.framesSent, 3)
    }

    func testRefusedFrameRequestsKeyframeAndKeepsSequence() async {
        let transport = FakeTransport()
        transport.accept = false
        let requests = LockedCounter()
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: { requests.increment() })
        sender.start()
        frames.push(key(1))
        await waitUntil("keyframe requested") { requests.value == 1 }
        XCTAssertEqual(sender.currentCounters.framesRejected, 1)
        transport.accept = true
        frames.push(key(2))
        await waitUntil("frame sent") { transport.sentCount == 1 }
        XCTAssertEqual(transport.sent.first?.frameSeq, 0, "a refused frame does not consume a sequence number")
        await sender.stop()
    }

    func testSenderStampsWriteTimesIntoTrace() async {
        let transport = FakeTransport()
        let traces = LockedValue<[FrameTrace]>([])
        let clockValue = LockedValue<UInt64>(1_000)
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: {},
                                 trace: { t in traces.set(traces.get() + [t]) },
                                 clock: { let v = clockValue.get(); clockValue.set(v + 500); return v })
        sender.start()
        var f = delta(1)
        f.trace.captureUs = 1; f.trace.deliveredUs = 2; f.trace.submittedUs = 3; f.trace.encodedUs = 4; f.trace.enqueuedUs = 5
        frames.push(key(0))  // first frame: keyframe, also traced (incomplete ones are filtered by the window)
        frames.push(f)
        await waitUntil("sent") { transport.sentCount == 2 }
        transport.complete()
        transport.complete()
        await waitUntil("traced") { traces.get().count == 2 }
        let t = traces.get()[1]
        XCTAssertEqual(t.deliveredUs, 2)
        XCTAssertGreaterThan(t.writeStartUs, 0)
        XCTAssertGreaterThan(t.writeDoneUs, t.writeStartUs)
        // T-122: keyframe flag and payload size travel with the trace (keyframe write stats, coalescing).
        let k = traces.get()[0]
        XCTAssertTrue(k.isKeyframe)
        XCTAssertFalse(t.isKeyframe)
        XCTAssertEqual(k.bytes, transport.sent.first?.data.count)
        await sender.stop()
    }

    func testTransportFailureEndsSender() async {
        let transport = FakeTransport()
        let ended = LockedValue<VideoSender.EndReason?>(nil)
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: {},
                                 onEnded: { ended.set($0) })
        sender.start()
        frames.push(key(1))
        await waitUntil("sent") { transport.sentCount == 1 }
        transport.complete(false)  // no further frame arrives: the sender must still end promptly
        await waitUntil("ended") { ended.get() != nil }
        guard case .transportFailed? = ended.get() else { return XCTFail("expected transportFailed") }
        XCTAssertEqual(sender.currentCounters.sendFailures, 1)
    }

    func testStopEndsSenderWhileWaitingAndClearsHandler() async {
        let transport = FakeTransport()
        transport.limit = 0  // stuck socket
        let ended = LockedValue<VideoSender.EndReason?>(nil)
        let sender = VideoSender(transport: transport, frames: VideoFrameQueue(keyframeNeeded: {}),
                                 requestKeyframe: {}, onEnded: { ended.set($0) })
        sender.start()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await sender.stop()
        guard case .cancelled? = ended.get() else { return XCTFail("expected cancelled") }
    }

    func testStopEndsSenderWhileWaitingForFrames() async {
        let transport = FakeTransport()
        let frames = VideoFrameQueue(keyframeNeeded: {})
        let sender = VideoSender(transport: transport, frames: frames, requestKeyframe: {})
        sender.start()
        try? await Task.sleep(nanoseconds: 20_000_000)
        await sender.stop()  // must return, not hang on the empty queue
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func set(_ new: T) { lock.withLock { v = new } }
    func get() -> T { lock.withLock { v } }
}

final class StatsSummaryTests: XCTestCase {
    func testSummary() {
        let s = StatsSummary(Stats(intervalMs: 1000, framesReceived: 60, framesDecoded: 60, framesRendered: 58,
                                   framesDropped: 2, decodeTimeAvgUs: 4500, latencyAvgUs: 35_000,
                                   bytesReceived: 3_750_000))
        XCTAssertEqual(s.fps, 58, accuracy: 0.001)
        XCTAssertEqual(s.bitrateKbps, 30_000, accuracy: 0.001)
        XCTAssertEqual(s.latencyMs ?? 0, 35, accuracy: 0.001)
        XCTAssertEqual(s.menuText, "58 fps · 30.0 Mbit/s · 35 ms")
        XCTAssertTrue(s.logFields.contains("fps=58.0"))
        XCTAssertTrue(s.logFields.contains("dropped=2"))
    }

    func testUnknownLatencyAndZeroInterval() {
        let s = StatsSummary(Stats(intervalMs: 0, framesReceived: 1, framesDecoded: 1, framesRendered: 1,
                                   framesDropped: 0, decodeTimeAvgUs: 0, latencyAvgUs: 0, bytesReceived: 100))
        XCTAssertEqual(s.fps, 0)
        XCTAssertNil(s.latencyMs)
        XCTAssertFalse(s.menuText.contains(" ms"))
        XCTAssertTrue(s.logFields.hasSuffix("latency_ms=unknown"))
    }
}

final class RotatingLogFileTests: XCTestCase {
    private func makeDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAppendsLinesAndSetsPermissions() throws {
        let dir = makeDir()
        let log = RotatingLogFile(directory: dir)
        log.append("one")
        log.append("two")
        log.close()
        let text = try String(contentsOf: dir.appendingPathComponent("host.log"), encoding: .utf8)
        XCTAssertEqual(text, "one\ntwo\n")
        let mode = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("host.log").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testDropsOldestWhenBufferFullAndCountsThem() throws {
        let dir = makeDir()
        let log = RotatingLogFile(directory: dir, maxPendingLines: 10)
        for i in 0..<2000 { log.append("l\(i)") }
        log.close()
        let text = try String(contentsOf: dir.appendingPathComponent("host.log"), encoding: .utf8)
        let written = text.split(separator: "\n").filter { $0.hasPrefix("l") }.count
        XCTAssertEqual(written + log.droppedLines, 2000, "every line is either written or counted as dropped")
        XCTAssertTrue(text.contains("l1999"), "newest lines are kept")
    }

    func testTightensExistingModes() throws {
        let dir = makeDir()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: dir.appendingPathComponent("host.log").path, contents: nil,
                                       attributes: [.posixPermissions: 0o644])
        let log = RotatingLogFile(directory: dir)
        log.append("x")
        log.close()
        let fm = FileManager.default
        XCTAssertEqual(try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try fm.attributesOfItem(atPath: dir.appendingPathComponent("host.log").path)[.posixPermissions] as? Int, 0o600)
    }

    func testRotationKeepsBoundedFiles() throws {
        let dir = makeDir()
        let log = RotatingLogFile(directory: dir, maxBytes: 20, keep: 3)
        for i in 0..<20 { log.append("line-\(i)") }  // 7-8 bytes each: rotates several times
        log.close()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["host.1.log", "host.2.log", "host.log"], "at most `keep` files")
        let newest = try String(contentsOf: dir.appendingPathComponent("host.log"), encoding: .utf8)
        XCTAssertTrue(newest.contains("line-19"))
        for n in names {
            let size = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int ?? 0
            XCTAssertLessThanOrEqual(size, 20)
        }
    }
}

final class BoundedMailboxTests: XCTestCase {
    func testCoalescedEventsKeepLatestAndDoNotCountAgainstCapacity() {
        let m = BoundedMailbox<String>(capacity: 2)
        for i in 0..<100 { m.post("stats\(i)", coalesceKey: 1) }
        m.post("kf", coalesceKey: 2)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.post("a"), .queued)
        XCTAssertEqual(m.post("b"), .queued)
        XCTAssertEqual(m.take(), "stats99", "coalesced entry keeps its position, newest value")
        XCTAssertEqual(m.take(), "kf")
        XCTAssertEqual(m.take(), "a")
    }

    func testLifecycleOverflowIsReportedNotStored() {
        let m = BoundedMailbox<Int>(capacity: 3)
        for i in 0..<3 { XCTAssertEqual(m.post(i), .queued) }
        XCTAssertEqual(m.post(3), .overflow)
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m.post(99, forced: true), .queued, "forced events bypass the cap")
        XCTAssertEqual(m.removeAll(), [0, 1, 2, 99])
        XCTAssertNil(m.take())
    }

    func testWakeSignalsConsumer() async {
        let m = BoundedMailbox<Int>()
        m.post(1)
        var it = m.wake.makeAsyncIterator()
        _ = await it.next()
        XCTAssertEqual(m.take(), 1)
    }
}
