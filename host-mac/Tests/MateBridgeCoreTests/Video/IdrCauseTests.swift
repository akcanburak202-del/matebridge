import XCTest
@testable import MateBridgeCore

/// T-371: every keyframe force carries a cause; coalesced and deferred requests are counted separately. Observation
/// only: the decisions themselves are covered by the other coalescer tests.
final class IdrCauseTests: XCTestCase {
    private let ms: UInt64 = 1000
    private typealias C = KeyframeRequestCoalescer

    private func awaiting(pushed: UInt64 = 0) -> KeyframeQueueState {
        .init(awaitingKeyframe: true, keyframeQueued: false, keyframesPushed: pushed)
    }

    func testClientRequestForcedIsRecorded() {
        var c = C()
        let d = c.request(.framesDropped, nowUs: 1000 * ms, keyframesPushed: 0)
        XCTAssertTrue(d.forceKeyframe)
        XCTAssertEqual(c.takeForceNotes(), [.init(cause: .clientRequest, sinceLastMs: nil)])
        XCTAssertEqual(c.takeCauses().forced, [.clientRequest: 1])
    }

    func testConfigReasonForcedIsRecordedAsClientRequest() {
        var c = C()
        _ = c.request(.decodeError, nowUs: 1000 * ms, keyframesPushed: 0, configResent: true)
        XCTAssertEqual(c.takeForceNotes().map(\.cause), [.clientRequest])
    }

    func testCoalescedRequestIsCountedNotForced() {
        var c = C()
        _ = c.request(.framesDropped, nowUs: 1000 * ms, keyframesPushed: 0)
        let d = c.request(.framesDropped, nowUs: 1050 * ms, keyframesPushed: 0)
        XCTAssertFalse(d.forceKeyframe)
        let w = c.takeCauses()
        XCTAssertEqual(w.forced, [.clientRequest: 1])
        XCTAssertEqual(w.coalesced, 1)
        XCTAssertEqual(c.takeForceNotes().count, 1)
    }

    func testTransportRefusedAndOtherInternalForces() {
        var c = C()
        c.internalForce(nowUs: 1000 * ms, keyframesPushed: 0, cause: .transportRefused)
        c.internalForce(nowUs: 1700 * ms, keyframesPushed: 0)
        let notes = c.takeForceNotes()
        XCTAssertEqual(notes, [.init(cause: .transportRefused, sinceLastMs: nil), .init(cause: .other, sinceLastMs: 700)])
    }

    func testQueueOverflowForcedImmediately() {
        var c = C()
        let d = c.hostDrop(nowUs: 5000 * ms, queue: awaiting())
        XCTAssertTrue(d.forceKeyframe)
        XCTAssertEqual(c.takeForceNotes().map(\.cause), [.queueOverflow])
        XCTAssertEqual(c.takeCauses().forced, [.queueOverflow: 1])
    }

    func testDeferredHostDropIsCountedAndForcedLaterAsQueueOverflow() {
        var c = C()
        c.keyframeWritten(nowUs: 5000 * ms, bytes: 1000)   // unforced: periodic
        _ = c.takeForceNotes()
        _ = c.takeCauses()
        let d = c.hostDrop(nowUs: 5100 * ms, queue: awaiting(pushed: 1))
        XCTAssertFalse(d.forceKeyframe)
        XCTAssertTrue(c.takeForceNotes().isEmpty)
        let w = c.takeCauses()
        XCTAssertEqual(w.deferred, 1)
        XCTAssertTrue(w.forced.isEmpty)
        let later = c.checkDeferred(nowUs: 5000 * ms + C.defaultWindowUs + ms, queue: awaiting(pushed: 1))
        XCTAssertTrue(later.forceKeyframe)
        XCTAssertEqual(c.takeForceNotes().map(\.cause), [.queueOverflow])
    }

    func testResetIsConsumer() {
        var c = C()
        c.reset(nowUs: 1000 * ms, keyframesPushed: 0)
        XCTAssertEqual(c.takeForceNotes().map(\.cause), [.consumer])
    }

    func testUnforcedKeyframeWriteIsPeriodicAndForcedOneIsNot() {
        var c = C()
        c.keyframeWritten(nowUs: 1000 * ms, bytes: 10)
        XCTAssertEqual(c.takeForceNotes().map(\.cause), [.periodic])
        _ = c.request(.framesDropped, nowUs: 2000 * ms, keyframesPushed: 0)
        _ = c.takeForceNotes()
        c.keyframeWritten(nowUs: 2100 * ms, bytes: 10)
        XCTAssertTrue(c.takeForceNotes().isEmpty)
    }

    func testSinceLastMsAndCauseWindowReset() {
        var c = C()
        c.internalForce(nowUs: 1000 * ms, keyframesPushed: 0, cause: .transportRefused)
        _ = c.request(.framesDropped, nowUs: 1400 * ms, keyframesPushed: 0)   // coalesced: pending
        c.keyframeWritten(nowUs: 1500 * ms, bytes: 10)
        _ = c.request(.framesDropped, nowUs: 2000 * ms, keyframesPushed: 1)
        XCTAssertEqual(c.takeForceNotes().map(\.sinceLastMs), [nil, 1000])
        XCTAssertEqual(c.takeCauses().forced, [.transportRefused: 1, .clientRequest: 1])
        XCTAssertEqual(c.takeCauses(), .init())
    }

    func testLogFields() {
        XCTAssertEqual(C.ForceNote(cause: .queueOverflow, sinceLastMs: 250).logFields,
                       "cause=queue_overflow since_last_ms=250")
        XCTAssertEqual(C.ForceNote(cause: .periodic, sinceLastMs: nil).logFields, "cause=periodic since_last_ms=-")
        let w = C.CauseWindow(forced: [.clientRequest: 2, .queueOverflow: 3, .consumer: 0], coalesced: 4, deferred: 1)
        XCTAssertEqual(w.logFields, " idr_cause_queue_overflow=3 idr_cause_client_request=2 idr_coalesced=4 idr_deferred=1")
        XCTAssertEqual(C.CauseWindow().logFields, "")
        XCTAssertEqual(C.StatsWindow(window: .init(count: 1, bytesMax: 5), causes: .init()).logFields,
                       "idr=1 idr_bytes_max=5")
    }

    func testNotesAreBounded() {
        var c = C()
        for i in 0..<100 { c.internalForce(nowUs: UInt64(i) * ms, keyframesPushed: 0) }
        XCTAssertEqual(c.takeForceNotes().count, 32)
        XCTAssertEqual(c.takeCauses().forced[.other], 100)
    }
}
