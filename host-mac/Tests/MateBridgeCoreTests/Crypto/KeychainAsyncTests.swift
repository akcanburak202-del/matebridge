import Foundation
import Testing
@testable import MateBridgeCore

// Round 2: the Keychain never blocks the session queue (async lookup with a 5 s bound), every Keychain operation is
// serialized in enqueue order, and per-session settings follow the activating connection's HELLO.

private let A = ConnectionID(1)
private let B = ConnectionID(2)
private let sec: UInt64 = 1_000_000
private let pairKey = SecretBytes([UInt8](repeating: 0x5a, count: 32))

private func device(_ n: UInt8) -> DeviceID { DeviceID(bytes: [UInt8](repeating: n, count: 16))! }

private func config(_ hello: Hello) -> StreamConfig {
    StreamConfig(configID: 1, codec: .hevc, widthPx: hello.screenWidthPx, heightPx: hello.screenHeightPx,
                 widthPt: hello.screenWidthPx / 2, heightPt: hello.screenHeightPx / 2, fps: 60, bitrateKbps: 40_000,
                 colorPrimaries: 1, transfer: 13, matrix: 1, fullRange: true)
}

/// A machine in the app's configuration: no inline store, so pair keys arrive through `pairKeyResolved`.
private func asyncMachine(approved: Set<DeviceID> = [device(1)],
                          makeConfig: @escaping @Sendable (Hello) -> StreamConfig = config) -> SessionMachine {
    var m = SessionMachine(configuration: .init(hostName: "Mac", makeStreamConfig: makeConfig,
                                                makeSessionID: { 77 }, pairKeys: nil), approvedDevices: approved)
    m.configuration.releaseSilenceUs = 1000 * sec
    m.configuration.closeSilenceUs = 1000 * sec
    m.videoPort = 5555
    return m
}

private func lookups(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .lookupPairKey(let id, _) = $0 { id } else { nil } }
}

private func sends(_ actions: [SessionAction]) -> [ConnectionID] {
    actions.compactMap { if case .send(let id, _) = $0 { id } else { nil } }
}

/// A store whose operations block until released; records the order in which they ran.
private final class BlockingStore: PairKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [DeviceID: SecretBytes] = [:]
    private var log: [String] = []
    private let gate = DispatchSemaphore(value: 0)
    var blockFirstOperation = true

    var order: [String] { lock.withLock { log } }

    private func record(_ op: String) {
        let shouldBlock = lock.withLock { () -> Bool in
            let first = log.isEmpty && blockFirstOperation
            log.append(op)
            return first
        }
        if shouldBlock { gate.wait() }
    }

    func release() { gate.signal() }

    func key(for device: DeviceID) -> SecretBytes? {
        record("lookup")
        return lock.withLock { keys[device] }
    }
    func save(_ key: SecretBytes, for device: DeviceID) throws {
        record("save")
        lock.withLock { keys[device] = key }
    }
    func remove(_ device: DeviceID) throws {
        record("remove")
        lock.withLock { keys[device] = nil }
    }
    func removeAll() throws {
        record("removeAll")
        lock.withLock { keys.removeAll() }
    }
}

@Suite struct AsyncPairKeyLookupTests {
    @Test func aPendingLookupSendsNothingAndNeverDelaysTheLiveSession() {
        var m = asyncMachine()
        // A is live (lookup resolved).
        _ = m.connectionOpened(A, now: 0)
        #expect(lookups(m.received(A, TestClient(device: 1).message, now: 0)) == [A])
        _ = m.pairKeyResolved(A, key: pairKey, now: 0)
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))

        // B asks; its lookup is pending (the Keychain is stuck). Nothing is sent to B, A is untouched.
        _ = m.connectionOpened(B, now: 1 * sec)
        let hello = m.received(B, TestClient(device: 1, eph: EphemeralKeyPair()).message, now: 1 * sec)
        #expect(lookups(hello) == [B] && sends(hello).isEmpty)
        #expect(!hello.contains { if case .startEncryption = $0 { true } else { false } })

        // The live session's release paths work while the lookup is pending.
        let release = m.received(A, .releaseAll(.focusLost), now: 2 * sec)
        #expect(release == [.releaseInput(A, .clientRequest(.focusLost))])
        let bye = m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 3 * sec)
        #expect(sends(bye) == [A])

        // More than 5 s without an answer: only B is closed, and it never got a byte.
        #expect(m.tick(now: 6 * sec - 1).isEmpty)
        let timeout = m.tick(now: 6 * sec)
        #expect(timeout.contains(.close(B)) && sends(timeout).isEmpty)
        #expect(!timeout.contains(.close(A)) && !timeout.contains { if case .releaseInput = $0 { true } else { false } })
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
        // A late answer for the closed connection is ignored.
        #expect(m.pairKeyResolved(B, key: pairKey, now: 7 * sec).isEmpty)
    }

    @Test func aLookupThatIsStillPendingDoesNotBlockTheLiveSessionShutdown() {
        var m = asyncMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        _ = m.pairKeyResolved(A, key: pairKey, now: 0)
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, TestClient(device: 1, eph: EphemeralKeyPair()).message, now: 1)
        let shutdown = m.shutdown()
        #expect(shutdown.contains(.releaseInput(A, .shutdown)))
        #expect(shutdown.contains(.close(B)))
        #expect(m.pairKeyResolved(B, key: pairKey, now: 2).isEmpty)
    }

    @Test func resolvedKeyContinuesTheHandshakeAsPaired() throws {
        var m = asyncMachine()
        var client = TestClient(device: 1)
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, client.message, now: 0)
        let actions = m.pairKeyResolved(A, key: pairKey, now: 1)
        guard case .send(A, .helloAck(let ack))? = actions.first else { Issue.record("no ack"); return }
        #expect(ack.status == .accepted && ack.keyMode == .paired)
        try client.receiveFirstAck(ack, pairKey: pairKey)
        let started = actions.compactMap { a -> ControlKeys? in if case .startEncryption(_, let k) = a { k } else { nil } }
        #expect(started == [client.schedule!.control])
    }

    @Test func missingKeyFallsBackToPairing() {
        var m = asyncMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        let actions = m.pairKeyResolved(A, key: nil, now: 1)
        guard case .send(A, .helloAck(let ack))? = actions.first else { Issue.record("no ack"); return }
        #expect(ack.keyMode == .pairing && ack.status == .pendingApproval)
    }

    @Test func unapprovedDeviceNeedsNoLookup() {
        var m = asyncMachine(approved: [])
        _ = m.connectionOpened(A, now: 0)
        let actions = m.received(A, TestClient(device: 1).message, now: 0)
        #expect(lookups(actions).isEmpty)
        guard case .send(A, .helloAck(let ack))? = actions.first else { Issue.record("no ack"); return }
        #expect(ack.keyMode == .pairing)
    }

    @Test func otherDeviceIsBusyWithoutALookup() {
        var m = asyncMachine(approved: [device(1), device(2)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        _ = m.pairKeyResolved(A, key: pairKey, now: 0)
        _ = m.connectionOpened(B, now: 1)
        let actions = m.received(B, TestClient(device: 2).message, now: 1)
        #expect(lookups(actions).isEmpty)
        #expect(actions.contains { if case .send(B, .helloAck(let a)) = $0 { a.status == .busy } else { false } })
    }

    @Test func theSlotIsRechecksAfterTheLookupReturns() {
        // While A's lookup was pending another device took the slot: A's answer must not start a second session.
        var m = asyncMachine(approved: [device(1), device(2)])
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)  // lookup pending
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, TestClient(device: 2).message, now: 1)  // lookup pending too
        _ = m.pairKeyResolved(B, key: pairKey, now: 2)  // B gets the slot
        let late = m.pairKeyResolved(A, key: pairKey, now: 3)
        #expect(late.contains { if case .send(A, .helloAck(let a)) = $0 { a.status == .busy } else { false } })
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))
    }

    @Test func aConnectionClosedDuringTheLookupIsForgotten() {
        var m = asyncMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        _ = m.connectionClosed(A)
        #expect(m.pairKeyResolved(A, key: pairKey, now: 1).isEmpty)
        #expect(m.status == .idle && m.awaitingHelloCount == 0)
    }

    @Test func messagesBeforeTheAckAreAProtocolError() {
        var m = asyncMachine()
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, TestClient(device: 1).message, now: 0)
        #expect(m.received(A, .ping(Ping(seq: 1, senderTimeUs: 0)), now: 1).contains(.send(A, .bye(.protocolError))))
    }
}

@Suite struct PairKeyServiceTests {
    private func wait(_ ok: () -> Bool, timeout: TimeInterval = 3) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if ok() { return true }; Thread.sleep(forTimeInterval: 0.005) }
        return ok()
    }

    @Test func enqueuingNeverBlocksTheCallerEvenWhileTheStoreBlocks() {
        let store = BlockingStore()  // the first operation blocks until released
        let service = PairKeyService(store: store)
        let answered = Atomic<Bool>(false)
        let start = Date()
        service.lookup(device(1)) { _ in answered.set(true) }
        service.save(pairKey, for: device(2)) { _ in }
        #expect(Date().timeIntervalSince(start) < 0.5)  // returned at once
        #expect(!answered.get())
        store.release()
        let ok = wait { answered.get() }
        #expect(ok)
    }

    @Test func forgetEnqueuedBeforeALaterPairingNeverDeletesTheFreshKey() {
        let store = BlockingStore()
        let service = PairKeyService(store: store)
        let saved = Atomic<Bool>(false)
        let looked = Atomic<SecretBytes?>(nil)
        let done = Atomic<Bool>(false)
        // "Forget" first (its Keychain call is stuck), then a new pairing's save, then a lookup.
        service.removeAll { _ in }
        service.save(pairKey, for: device(1)) { saved.set($0) }
        service.lookup(device(1)) { looked.set($0); done.set(true) }
        let first = wait { store.order == ["removeAll"] }
        #expect(first)
        #expect(!saved.get())  // the save waits behind the delete
        store.release()
        let finished = wait { done.get() }
        #expect(finished)
        #expect(store.order == ["removeAll", "save", "lookup"])
        #expect(saved.get() && looked.get() == pairKey)  // the fresh key survived
    }

    @Test func compareAndDeleteKeepsANewerKeyOfTheSameDevice() {
        let store = InMemoryPairKeyStore()
        let service = PairKeyService(store: store)
        let old = SecretBytes([UInt8](repeating: 0x11, count: 32))
        let newer = SecretBytes([UInt8](repeating: 0x22, count: 32))
        let done = Atomic<Bool>(false)
        // An abandoned pairing saved `old`; another pairing of the same device saved `newer` before the cleanup ran.
        service.save(old, for: device(1)) { _ in }
        service.save(newer, for: device(1)) { _ in }
        service.remove(device(1), ifEquals: old) { _ in done.set(true) }
        let ok = wait { done.get() }
        #expect(ok)
        #expect(store.key(for: device(1)) == newer)
        // The cleanup still removes the key it stored itself.
        let again = Atomic<Bool>(false)
        service.remove(device(1), ifEquals: newer) { _ in again.set(true) }
        let ok2 = wait { again.get() }
        #expect(ok2)
        #expect(store.key(for: device(1)) == nil)
    }

    @Test func lookupsAreBoundedAndTheOverflowIsRefused() {
        let store = BlockingStore()  // the first lookup blocks inside the store
        let service = PairKeyService(store: store)
        let answered = Atomic<Int>(0)
        var accepted = 0
        for _ in 0..<(PairKeyService.maxPendingLookups + 4) {
            if service.lookup(device(1), completion: { _ in answered.set(answered.get() + 1) }) { accepted += 1 }
        }
        #expect(accepted == PairKeyService.maxPendingLookups)
        store.release()
        let ok = wait { answered.get() == PairKeyService.maxPendingLookups }
        #expect(ok)
        // Room again once they drained.
        let more = service.lookup(device(1)) { _ in }
        #expect(more)
    }

    @Test func staleLookupsAreSkippedWithoutTouchingTheStore() {
        let store = BlockingStore()
        let service = PairKeyService(store: store)
        let flag = Atomic<Bool>(true)
        let answers = Atomic<[String]>([])
        service.lookup(device(1), completion: { _ in answers.set(answers.get() + ["first"]) })  // blocks in the store
        service.lookup(device(2), isCurrent: { flag.get() }, completion: { _ in answers.set(answers.get() + ["stale"]) })
        service.lookup(device(3), isCurrent: { true }, completion: { _ in answers.set(answers.get() + ["live"]) })
        let started = wait { store.order == ["lookup"] }
        #expect(started)
        flag.set(false)  // the second connection closed while it waited
        store.release()
        let ok = wait { answers.get() == ["first", "live"] }
        #expect(ok)
        #expect(store.order == ["lookup", "lookup"])  // the stale one never reached the store
    }

    @Test func aSaveCompletionMeansTheKeyIsStored() {
        let store = InMemoryPairKeyStore()
        let service = PairKeyService(store: store)
        let done = Atomic<Bool?>(nil)
        service.save(pairKey, for: device(3)) { ok in
            // When the completion runs the key is already readable (ACCEPTED is sent only after this).
            done.set(ok && store.key(for: device(3)) == pairKey)
        }
        let ok = wait { done.get() == true }
        #expect(ok)
    }

    @Test func failuresAreReportedNotThrown() {
        let store = InMemoryPairKeyStore()
        store.failSaves = true
        let service = PairKeyService(store: store)
        let result = Atomic<Bool?>(nil)
        service.save(pairKey, for: device(1)) { result.set($0) }
        let ok = wait { result.get() == false }
        #expect(ok)
    }
}

/// Minimal thread-safe box for test results.
private final class Atomic<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}

@Suite struct SessionSettingsBindingTests {
    @Test func anUnprovenTakeoverNeverTouchesTheLiveSessionsSettingsAndActivationCarriesItsOwnHello() {
        // `makeStreamConfig` runs for B at HELLO (to put the config into the ACK) but must have no effect until B
        // activates; the activation then carries B's own HELLO (what the coordinator derives settings from).
        let calls = Atomic<[UInt16]>([])
        var m = asyncMachine { hello in
            calls.set(calls.get() + [hello.screenWidthPx])
            return config(hello)
        }
        var a = TestClient(device: 1)
        a.hello.screenWidthPx = 2800
        _ = m.connectionOpened(A, now: 0)
        _ = m.received(A, a.message, now: 0)
        let startedA = m.pairKeyResolved(A, key: pairKey, now: 0)
        let helloA = startedA.compactMap { act -> Hello? in if case .sessionStarted(_, _, _, let h) = act { h } else { nil } }
        #expect(helloA.count == 1 && helloA[0].screenWidthPx == 2800)

        var b = TestClient(device: 1, eph: EphemeralKeyPair())
        b.hello.screenWidthPx = 1920
        b.hello.screenHeightPx = 1200
        _ = m.connectionOpened(B, now: 1)
        _ = m.received(B, b.message, now: 1)
        let proving = m.pairKeyResolved(B, key: pairKey, now: 1)
        // B is only proving: no session start for it, so nothing is handed to the coordinator.
        #expect(!proving.contains { if case .sessionStarted = $0 { true } else { false } })
        #expect(calls.get() == [2800, 1920])  // the ACK's config was computed, nothing else happened
        #expect(m.status == .active(deviceName: "Pad", sessionID: 77))

        // Unproven B times out: A stays, and no session was ever announced for B.
        let timeout = m.tick(now: 7 * sec)
        #expect(timeout.contains(.close(B)))
        #expect(!timeout.contains { if case .sessionStarted = $0 { true } else { false } })

        // A second reconnect that does prove: its activation carries *its* HELLO.
        _ = m.connectionOpened(ConnectionID(3), now: 8 * sec)
        _ = m.received(ConnectionID(3), b.message, now: 8 * sec)
        _ = m.pairKeyResolved(ConnectionID(3), key: pairKey, now: 8 * sec)
        let proof = m.received(ConnectionID(3), .ping(Ping(seq: 1, senderTimeUs: 0)), now: 9 * sec)
        let helloB = proof.compactMap { act -> Hello? in if case .sessionStarted(_, _, _, let h) = act { h } else { nil } }
        #expect(helloB.count == 1 && helloB[0].screenWidthPx == 1920 && helloB[0].screenHeightPx == 1200)
    }
}
