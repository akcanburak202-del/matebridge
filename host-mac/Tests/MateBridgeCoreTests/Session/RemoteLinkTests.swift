import Foundation
import Testing
@testable import MateBridgeCore

// T-337 (decision 0038): the host side of the remote (least data) profile: STREAM_PREFS fps 15/30, the 500 kbps floor,
// the `link` group, and everything `link = 1` changes for a session (heartbeat, cursor keep-alive, byte budgets,
// remembered prefs, tablet files).

private let sec: UInt64 = 1_000_000
private let A = ConnectionID(1)

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))
private let config = StreamConfig(configID: 1, codec: .h264, widthPx: 2800, heightPx: 1840, widthPt: 1400,
                                  heightPt: 920, fps: 60, bitrateKbps: 40000, colorPrimaries: 1, transfer: 1,
                                  matrix: 1, fullRange: true)

private func framed(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let n = UInt32(payload.count)
    return [type, UInt8(n & 0xff), UInt8((n >> 8) & 0xff), UInt8((n >> 16) & 0xff), UInt8(n >> 24)] + payload
}

private func decode(_ bytes: [UInt8]) throws -> Message? {
    var d = FrameDecoder(connection: .control)
    d.append(bytes)
    return try d.nextMessage()
}

/// The 16-byte payload of `stream_prefs_remote`, cut to `count` bytes.
private func remotePayload(_ count: Int) -> [UInt8] {
    let full: [UInt8] = [15, 0, 0xe8, 0x03, 0xe8, 0x03, 0, 0, 0x78, 0x05, 0x98, 0x03, 0, 0, 1, 0]
    return Array(full.prefix(count))
}

private func makeMachine(ping: UInt64? = nil) -> SessionMachine {
    let approved: Set<DeviceID> = [device(1)]
    let keys = InMemoryPairKeyStore(keys: [device(1): pairKey])
    var c = SessionMachine.Configuration(hostName: "Mac", makeStreamConfig: { _ in config }, makeSessionID: { 77 },
                                         pairKeys: keys)
    c.hostPingIntervalUs = ping
    return SessionMachine(configuration: c, approvedDevices: approved)
}

private func activate(_ m: inout SessionMachine, now: UInt64 = 0) {
    _ = m.connectionOpened(A, now: now)
    _ = m.received(A, .hello(TestClient(device: 1).hello), now: now)
    _ = m.received(A, .ping(Ping(seq: 0, senderTimeUs: 0)), now: now)
}

private func remotePrefs() -> Message {
    .streamPrefs(StreamPrefs(fps: 15, scalePermille: 1000, bitrateKbps: 1000, displayWidthPx: 1400,
                             displayHeightPx: 920, link: 1))
}

private func isRelease(_ a: SessionAction) -> Bool { if case .releaseInput = a { true } else { false } }
private func isClose(_ a: SessionAction) -> Bool { if case .close = a { true } else { false } }
private func pings(_ actions: [SessionAction]) -> Int {
    actions.filter { if case .send(_, .ping) = $0 { true } else { false } }.count
}

@Suite struct RemoteLinkTests {
    // MARK: STREAM_PREFS codec

    @Test(arguments: [8, 12, 14, 16])
    func prefsPayloadLengthsDecode(count: Int) throws {
        let m = try decode(framed(0x05, remotePayload(count)))
        guard case .streamPrefs(let p)? = m else { Issue.record("not stream prefs"); return }
        #expect(p.fps == 15 && p.bitrateKbps == 1000)
        #expect(p.displayWidthPx == (count >= 12 ? 1400 : 0))
        #expect(p.link == (count >= 16 ? 1 : 0))
    }

    @Test(arguments: [9, 10, 11, 13, 15])
    func prefsPartialGroupsAreTooShort(count: Int) {
        #expect(throws: ProtocolError.payloadTooShort(type: 0x05)) { try decode(framed(0x05, remotePayload(count))) }
    }

    @Test func prefsLongerPayloadIgnoresTheTail() throws {
        let m = try decode(framed(0x05, remotePayload(16) + [9, 9, 9]))
        guard case .streamPrefs(let p)? = m else { Issue.record("not stream prefs"); return }
        #expect(p.link == 1)
    }

    @Test func linkGroupIsWrittenOnlyForLinkAndPullsTheEarlierGroups() throws {
        func payloadCount(_ p: StreamPrefs) throws -> Int { try Message.streamPrefs(p).encode().count - 5 }
        #expect(try payloadCount(StreamPrefs(fps: 60, scalePermille: 1000)) == 8)
        #expect(try payloadCount(StreamPrefs(fps: 60, scalePermille: 1000, displayWidthPx: 1400, displayHeightPx: 920)) == 12)
        #expect(try payloadCount(StreamPrefs(fps: 60, scalePermille: 1000, dynamicRange: 1)) == 14)
        #expect(try payloadCount(StreamPrefs(fps: 15, scalePermille: 1000, link: 1)) == 16)
    }

    @Test func unknownLinkValuesCountAsNormal() {
        for raw: UInt8 in [0, 2, 3, 0xff] {
            let p = StreamPrefs(fps: 60, scalePermille: 1000, link: raw)
            #expect(p.normalized.link == 0 && !p.normalized.isRemote)
        }
        #expect(StreamPrefs(fps: 60, scalePermille: 1000, link: 1).normalized.isRemote)
    }

    // MARK: fps and bit rate

    @Test(arguments: [15, 30, 60, 120, 144])
    func supportedFpsAreKept(fps: Int) {
        #expect(StreamPrefs(fps: UInt16(fps), scalePermille: 1000).normalized.fps == UInt16(fps))
    }

    @Test(arguments: [0, 1, 14, 45, 90, 240])
    func otherFpsBecomeSixty(fps: Int) {
        #expect(StreamPrefs(fps: UInt16(fps), scalePermille: 1000).normalized.fps == 60)
    }

    @Test func userBitrateRangeStartsAt500() {
        #expect(VideoSettings.userBitrateRangeKbps == 500...150_000)
        #expect(BitrateRequest.defaultRange == 500...150_000)
        #expect(VideoSettings.clampedUserBitrateKbps(0) == nil)
        #expect(VideoSettings.clampedUserBitrateKbps(400) == 500)
        #expect(VideoSettings.clampedUserBitrateKbps(500) == 500)
        #expect(VideoSettings.clampedUserBitrateKbps(1000) == 1000)
        #expect(VideoSettings.clampedUserBitrateKbps(150_001) == 150_000)
        #expect(VideoSettings.parseBitrateKbps("500") == 500)
        #expect(VideoSettings.parseBitrateKbps("499") == nil)
    }

    @Test func remotePrefsGiveA15fps1MbpsGameDisplayAtSixtyHz() {
        guard case .streamPrefs(let prefs) = remotePrefs() else { return }
        let s = VideoSettings.tabletDefault.applying(prefs)
        #expect(s.fps == 15 && s.displayRefreshHz == 60)
        #expect(s.bitrateKbps == 1000 && s.userBitrateKbps == 1000)
        #expect(s.widthPx == 1400 && s.heightPx == 920 && !s.displayHiDPI)
        #expect(s.dynamicRange == .sdr && s.chromaPreference == .normal)
        #expect(s.streamConfig(configID: 2).fps == 15)
    }

    /// Why `defaultBitrateKbps` stays as it is: the remote profile always sends a bit rate, so the 20 Mbps floor of the
    /// mode default is never reached by a remote session.
    @Test func lowFpsWithoutABitrateKeepsTheModeDefaultFloor() {
        let s = VideoSettings.tabletDefault.applying(StreamPrefs(fps: 15, scalePermille: 1000))
        #expect(s.bitrateKbps == 20_000 && s.userBitrateKbps == nil)
    }

    // MARK: Frame pacing at 15 and 30 fps

    @Test(arguments: [15, 30])
    func pacerHoldsTheAverageRateAtLowFps(fps: Int) {
        // ScreenCaptureKit delivers at twice the stream fps (`minimumFrameInterval`) at most; a 60 Hz display with
        // changing content can deliver every 16.7 ms. Both must average out at the stream fps.
        for sourceHz in [2 * fps, 60] {
            var pacer = FramePacer<UInt64>(streamFps: fps)
            let step = 1_000_000 / UInt64(sourceHz)
            var sent = 0
            var arrival: UInt64 = 0
            var t: UInt64 = 0
            let end: UInt64 = 4 * sec
            while t <= end {
                if t >= arrival {
                    if case .submit = pacer.offer(arrival, ptsUs: arrival, nowUs: t, slotFree: true) { sent += 1 }
                    arrival += step
                }
                if case .submit = pacer.takePending(nowUs: t, slotFree: true) { sent += 1 }
                t += 1_000
            }
            #expect(sent >= fps * 4 - 2 && sent <= fps * 4 + 2, "fps \(fps) source \(sourceHz) Hz sent \(sent)")
        }
    }

    // MARK: Heartbeat

    @Test func remoteLinkKeeps1500msReleaseAndClosesAt15s() {
        var m = makeMachine()
        activate(&m, now: 0)
        _ = m.received(A, remotePrefs(), now: 100_000)
        #expect(m.tick(now: 1_599_999).isEmpty)
        #expect(m.tick(now: 1_600_000).contains(where: isRelease))  // a held key is still let go after 1.5 s
        #expect(!m.tick(now: 5_200_000).contains(where: isClose))  // the normal 5 s close no longer applies
        #expect(!m.tick(now: 15_099_999).contains(where: isClose))
        let closing = m.tick(now: 15_100_000)
        #expect(closing.contains(where: isClose))
        #expect(closing.contains { $0 == .releaseInput(A, .timeout) })
        #expect(m.status == .idle)
    }

    @Test func normalLinkStillClosesAt5s() {
        var m = makeMachine()
        activate(&m, now: 0)
        _ = m.received(A, .streamPrefs(StreamPrefs(fps: 60, scalePermille: 1000)), now: 100_000)
        #expect(m.tick(now: 5_100_000).contains(where: isClose))
    }

    @Test func untilTheFirstPrefsTheTimingsAreNormal() {
        var m = makeMachine()
        activate(&m, now: 0)
        #expect(m.tick(now: 5 * sec).contains(where: isClose))
    }

    @Test func aLaterNormalPrefsReturnsToTheNormalClose() {
        var m = makeMachine()
        activate(&m, now: 0)
        _ = m.received(A, remotePrefs(), now: 100_000)
        _ = m.received(A, .streamPrefs(StreamPrefs(fps: 60, scalePermille: 1000)), now: 200_000)
        #expect(m.tick(now: 5_300_000).contains(where: isClose))
    }

    @Test func aNewSessionStartsNormalAfterARemoteOne() {
        var m = makeMachine()
        activate(&m, now: 0)
        _ = m.received(A, remotePrefs(), now: 100_000)
        _ = m.received(A, .bye(.normal), now: 200_000)
        let b = ConnectionID(2)
        _ = m.connectionOpened(b, now: sec)
        _ = m.received(b, .hello(TestClient(device: 1).hello), now: sec)
        _ = m.received(b, .ping(Ping(seq: 0, senderTimeUs: 0)), now: sec)
        #expect(m.tick(now: 6_100_000).contains(where: isClose))
    }

    @Test func remoteHostPingGoesEveryTwoSeconds() {
        var m = makeMachine(ping: SessionMachine.Configuration.defaultHostPingIntervalUs)
        activate(&m, now: 0)
        _ = m.received(A, remotePrefs(), now: 50_000)
        #expect(pings(m.tick(now: 100_000)) == 1)  // the first one is due at once
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 1_000_000)
        #expect(pings(m.tick(now: 1_100_000)) == 0)
        _ = m.received(A, .ping(Ping(seq: 2, senderTimeUs: 0)), now: 2_000_000)
        #expect(pings(m.tick(now: 2_099_999)) == 0)
        #expect(pings(m.tick(now: 2_100_000)) == 1)
    }

    @Test func normalHostPingStaysAtHalfASecond() {
        var m = makeMachine(ping: SessionMachine.Configuration.defaultHostPingIntervalUs)
        activate(&m, now: 0)
        #expect(pings(m.tick(now: 100_000)) == 1)
        _ = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 400_000)
        #expect(pings(m.tick(now: 600_000)) == 1)
    }

    // MARK: Cursor keep-alive

    @Test func cursorKeepAliveIsTwoSecondsWhileRemote() {
        var p = CursorStreamPlanner()
        _ = p.prefs(enabled: true)
        let snap = CursorSnapshot(x: 1, y: 2, visible: true, shapeID: 3)
        _ = p.observe(snap, nowUs: 1_000_000)
        _ = p.videoCursorResult(ok: true)
        #expect(p.observe(snap, nowUs: 1_500_000).send == snap)  // normal: after 500 ms
        p.setKeepAlive(remote: true)
        #expect(p.keepAliveUs == 2_000_000)
        #expect(p.observe(snap, nowUs: 3_499_999).send == nil)
        #expect(p.observe(snap, nowUs: 3_500_000).send == snap)
        // A changed cursor still goes out at the normal change interval.
        let moved = CursorSnapshot(x: 5, y: 2, visible: true, shapeID: 3)
        #expect(p.observe(moved, nowUs: 3_510_000).send == moved)
    }

    @Test func cursorResetForgetsTheRemoteKeepAlive() {
        var p = CursorStreamPlanner()
        p.setKeepAlive(remote: true)
        p.reset()
        #expect(p.keepAliveUs == 500_000)
        p.setKeepAlive(remote: true)
        p.setKeepAlive(remote: false)
        #expect(p.keepAliveUs == 500_000)
    }

    // MARK: Byte budgets

    @Test func quarterSecondOfTheTargetBitRateWithA16KBFloor() {
        #expect(RemoteLinkProfile.bytes(bitrateKbps: 1000) == 31_250)
        #expect(RemoteLinkProfile.bytes(bitrateKbps: 2000) == 62_500)
        #expect(RemoteLinkProfile.bytes(bitrateKbps: 500) == 16_384)  // 15 625 would be below the floor
        #expect(RemoteLinkProfile.bytes(bitrateKbps: 0) == 16_384)
        #expect(RemoteLinkProfile.bytes(bitrateKbps: -5) == 16_384)
    }

    @Test func refineBudgetFollowsTheRemoteBitRateUnlessTheKnobIsSet() {
        let normal = StillRefineConfig.resolve(env: [:], transport: .network)
        #expect(normal.maxBytes == 256 * 1024)
        let remote = StillRefineConfig.resolve(env: [:], transport: .network, remoteKbps: 1000)
        #expect(remote.maxBytes == 31_250)
        let knob = StillRefineConfig.resolve(env: ["MATEBRIDGE_REFINE_KB": "64"], transport: .network, remoteKbps: 1000)
        #expect(knob.maxBytes == 64 * 1024)
        let remoteLow = StillRefineConfig.resolve(env: [:], transport: .network, remoteKbps: 500)
        #expect(remoteLow.maxBytes == 16 * 1024)
    }

    /// A link change with unchanged video settings adjusts the running policy live (no rebuild).
    @Test func refineCeilingChangesLiveOnARunningPolicy() {
        var p = StillRefinePolicy(config: StillRefineConfig.resolve(env: [:], transport: .network))
        #expect(p.config.maxBytes == 256 * 1024)
        p.noteCapture(nowUs: 0)
        let started = p.tick(nowUs: 300_000, queueReady: true).start
        #expect(started)
        p.setMaxBytes(RemoteLinkProfile.bytes(bitrateKbps: 1000))
        #expect(p.config.maxBytes == 31_250)
        var reason: StillRefineEnd?
        var total = 0
        for n in 1...15 where reason == nil {
            total += 5_000
            reason = p.noteOutput(bytes: 5_000, nowUs: UInt64(n), queueReady: true).report?.reason
        }
        #expect(reason == .maxBytes)  // under the old 256 KiB ceiling 15 frames of 5 000 B would all have gone out
        #expect(total <= 31_250 + 5_000)
    }

    @Test func linkUpdatesCoalesceToTheNewestValue() {
        // The mailbox both link mailboxes use: a burst schedules one drain and only the newest value survives.
        var box = EpochCoalescer<Bool>()
        var drains = 0
        for i in 0..<1000 where box.offer(i % 2 == 0, epoch: 1) { drains += 1 }
        #expect(drains == 1)
        let newest = box.take(epoch: 1)
        #expect(newest == false)  // 999 is odd
        let again = box.take(epoch: 1)
        #expect(again == nil)
        let next = box.offer(true, epoch: 2)
        #expect(next)  // the next burst schedules its own drain
        let old = box.take(epoch: 1)
        #expect(old == nil)  // a drain of an older epoch gets nothing
    }

    // MARK: Remembered prefs (T-049)

    @Test func remotePrefsAreNeverRemembered() {
        #expect(RemoteLinkProfile.persistsPrefs(StreamPrefs(fps: 60, scalePermille: 1000)))
        #expect(!RemoteLinkProfile.persistsPrefs(StreamPrefs(fps: 15, scalePermille: 1000, link: 1)))
        // The stored form has no link at all: whatever was saved reads back as a normal session.
        let stored = StreamPrefsStorageCodec.encode(StreamPrefs(fps: 15, scalePermille: 1000, bitrateKbps: 1000, link: 1))
        #expect(StreamPrefsStorageCodec.decode(stored)?.link == 0)
    }

    // MARK: Tablet files (FILES_NET OPEN)

    private func wifiPlanner() -> TabletFilesPlanner {
        var p = TabletFilesPlanner()
        #expect(p.sessionStarted(transport: .network, capable: true, netCapable: true).isEmpty)
        return p
    }

    @Test func remoteLinkSuppressesFilesNetOpen() {
        var p = wifiPlanner()
        #expect(p.filesInfo(.standby).isEmpty)
        #expect(p.linkChanged(remote: true).isEmpty)
        #expect(p.menu == .hidden)
        #expect(p.openRequested().isEmpty)  // no proxy, so no FILES_NET(OPEN)
        #expect(p.menu == .hidden)
    }

    @Test func remoteLinkClosesAnOpenShare() {
        var p = wifiPlanner()
        _ = p.filesInfo(.standby)
        var gen: UInt64?
        for case .startProxy(let g) in p.openRequested() { gen = g }
        let afterProxy = p.proxyFinished(generation: gen!, localPort: 47012, filesPort: 47003)
        #expect(afterProxy.contains { if case .sendFilesNet(let m) = $0 { m.isOpen } else { false } })
        let closing = p.linkChanged(remote: true)
        #expect(closing.contains { if case .sendFilesNet(let m) = $0 { !m.isOpen } else { false } })
        #expect(closing.contains { if case .stopProxy = $0 { true } else { false } })
        #expect(!p.remountsAfterRestart)
        // The tablet's STANDBY/READY after that does not bring a proxy back.
        #expect(!p.filesInfo(.standby).contains { if case .startProxy = $0 { true } else { false } })
    }

    @Test func backToNormalOffersTheVolumeAgain() {
        var p = wifiPlanner()
        _ = p.filesInfo(.standby)
        _ = p.linkChanged(remote: true)
        _ = p.linkChanged(remote: false)
        #expect(p.menu == .ready(lastMountFailed: false))
        #expect(p.openRequested().contains { if case .startProxy = $0 { true } else { false } })
    }

    @Test func aNewSessionIsNotRemote() {
        var p = wifiPlanner()
        _ = p.linkChanged(remote: true)
        _ = p.sessionEnded()
        _ = p.sessionStarted(transport: .network, capable: true, netCapable: true)
        _ = p.filesInfo(.standby)
        #expect(p.menu == .ready(lastMountFailed: false))
    }
}
