import Darwin
import XCTest
@testable import MateBridgeCore

/// T-091: partial-write buffer, backpressure gate and video socket knobs (pure parts).
final class SocketWriteBufferTests: XCTestCase {
    typealias Buffer = SocketWriteBuffer<String>

    /// A fake `write(2)`: replays scripted results and records what was actually written.
    private final class Writer {
        var script: [Buffer.WriteResult]
        var written: [UInt8] = []
        /// Each call's chunk start (the first byte offered).
        var offered: [[UInt8]] = []
        init(_ script: [Buffer.WriteResult]) { self.script = script }

        func write(_ chunk: UnsafeRawBufferPointer) -> Buffer.WriteResult {
            offered.append(Array(chunk))
            let r = script.isEmpty ? .wrote(chunk.count) : script.removeFirst()
            if case .wrote(let n) = r, n > 0, n <= chunk.count { written += chunk.prefix(n) }
            return r
        }
    }

    func testWholeRecordsCompleteInOrder() {
        var b = Buffer()
        b.append([1, 2, 3], token: "a")
        b.append([4, 5], token: "b")
        XCTAssertEqual(b.pendingBytes, 5)
        let w = Writer([])
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(done, ["a", "b"])
        XCTAssertEqual(w.written, [1, 2, 3, 4, 5])
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.pendingBytes, 0)
    }

    func testPartialWritesResumeAtOffsetAndNeverInterleave() {
        var b = Buffer()
        b.append([1, 2, 3, 4, 5], token: "a")
        b.append([6, 7, 8], token: "b")
        let w = Writer([.wrote(2), .wrote(1), .wouldBlock])
        var (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .wouldBlock)
        XCTAssertEqual(done, [])
        XCTAssertEqual(b.pendingBytes, 5)
        XCTAssertEqual(b.pendingRecords, 2)
        XCTAssertEqual(w.offered, [[1, 2, 3, 4, 5], [3, 4, 5], [4, 5]], "each write offers only the first record's tail")
        // Later the socket is writable again: the rest of record a, then record b.
        w.script = [.wrote(2), .wrote(1), .wrote(2)]
        (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(done, ["a", "b"])
        XCTAssertEqual(w.written, [1, 2, 3, 4, 5, 6, 7, 8], "byte stream is exactly a then b")
        XCTAssertEqual(w.offered.suffix(3), [[4, 5], [6, 7, 8], [7, 8]], "record b starts only after a ended")
    }

    func testCompletedRecordsAreReportedEvenWhenTheNextBlocks() {
        var b = Buffer()
        b.append([1], token: "a")
        b.append([2, 3], token: "b")
        let w = Writer([.wrote(1), .wrote(1), .wouldBlock])
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .wouldBlock)
        XCTAssertEqual(done, ["a"])
        XCTAssertEqual(b.pendingBytes, 1)
    }

    func testInterruptedIsRetried() {
        var b = Buffer()
        b.append([1, 2], token: "a")
        let w = Writer([.interrupted, .interrupted, .wrote(2)])
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(done, ["a"])
    }

    func testEndlessInterruptsGiveUpForNow() {
        var b = Buffer()
        b.append([1, 2], token: "a")
        let w = Writer(Array(repeating: .interrupted, count: 100))
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .wouldBlock)
        XCTAssertEqual(done, [])
        XCTAssertEqual(w.offered.count, Buffer.maxInterrupts)
        XCTAssertEqual(b.pendingBytes, 2, "nothing lost; retried on the next writable event")
    }

    func testFailureKeepsRecordsForRemoveAll() {
        var b = Buffer()
        b.append([1, 2, 3], token: "a")
        b.append([4], token: "b")
        let w = Writer([.wrote(1), .failed(EPIPE)])
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .failed(EPIPE))
        XCTAssertEqual(done, [])
        XCTAssertEqual(b.removeAll(), ["a", "b"], "every unfinished record is failed, in order")
        XCTAssertTrue(b.isEmpty)
        XCTAssertEqual(b.pendingBytes, 0)
    }

    func testZeroOrOversizedWriteIsTreatedAsBroken() {
        for bad in [Buffer.WriteResult.wrote(0), .wrote(9)] {
            var b = Buffer()
            b.append([1, 2, 3], token: "a")
            let (outcome, _) = b.drain(write: Writer([bad]).write)
            XCTAssertEqual(outcome, .failed(EIO), "\(bad)")
        }
    }

    func testAdmissionIsBoundedByRecordsAndBytes() {
        var b = Buffer()
        XCTAssertTrue(b.admits(byteCount: 10, maxRecords: 2, maxBytes: 10), "exactly at the byte limit")
        XCTAssertFalse(b.admits(byteCount: 11, maxRecords: 2, maxBytes: 10))
        b.append([1, 2, 3, 4, 5, 6], token: "a")
        _ = b.drain(write: Writer([.wrote(2), .wouldBlock]).write)  // 4 bytes of a still pending
        XCTAssertEqual(b.pendingBytes, 4)
        XCTAssertTrue(b.admits(byteCount: 6, maxRecords: 2, maxBytes: 10))
        XCTAssertFalse(b.admits(byteCount: 7, maxRecords: 2, maxBytes: 10), "counts the unwritten tail, not the record")
        b.append([7], token: "b")
        XCTAssertFalse(b.admits(byteCount: 1, maxRecords: 2, maxBytes: 10), "record limit")
        XCTAssertFalse(b.admits(byteCount: 0, maxRecords: 2, maxBytes: 10), "empty records count too")
    }

    func testEmptyRecordCompletesWithoutWrite() {
        var b = Buffer()
        b.append([], token: "a")
        let w = Writer([])
        let (outcome, done) = b.drain(write: w.write)
        XCTAssertEqual(outcome, .drained)
        XCTAssertEqual(done, ["a"])
        XCTAssertTrue(w.offered.isEmpty)
    }

    func testWriteResultFromErrno() {
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: 7, errno: 0), .wrote(7))
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: -1, errno: EAGAIN), .wouldBlock)
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: -1, errno: EWOULDBLOCK), .wouldBlock)
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: -1, errno: EINTR), .interrupted)
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: -1, errno: EPIPE), .failed(EPIPE))
        XCTAssertEqual(Buffer.WriteResult.from(returnValue: -1, errno: ECONNRESET), .failed(ECONNRESET))
    }

    // MARK: Gate

    func testGateNeedsNoRecordInFlightAndSocketBelowMark() {
        XCTAssertEqual(SocketVideoGate.maxRecordsInFlight, 1)
        XCTAssertTrue(SocketVideoGate.canSend(recordsInFlight: 0, socketBelowLowat: true))
        XCTAssertFalse(SocketVideoGate.canSend(recordsInFlight: 0, socketBelowLowat: false),
                       "unsent bytes above TCP_NOTSENT_LOWAT: the frame waits in the 2-frame queue (newest wins)")
        XCTAssertFalse(SocketVideoGate.canSend(recordsInFlight: 1, socketBelowLowat: true),
                       "a partially written record finishes before the next starts")
        XCTAssertFalse(SocketVideoGate.canSend(recordsInFlight: 1, socketBelowLowat: false))
    }

    // MARK: Knobs

    func testVideoSocketKnob() {
        XCTAssertEqual(VideoSocketKnob.parse([:]), .nw, "default stays Network.framework")
        XCTAssertEqual(VideoSocketKnob.parse(["MATEBRIDGE_VIDEO_SOCKET": "bsd"]), .bsd)
        XCTAssertEqual(VideoSocketKnob.parse(["MATEBRIDGE_VIDEO_SOCKET": " BSD "]), .bsd)
        XCTAssertEqual(VideoSocketKnob.parse(["MATEBRIDGE_VIDEO_SOCKET": "nw"]), .nw)
        XCTAssertEqual(VideoSocketKnob.parse(["MATEBRIDGE_VIDEO_SOCKET": "kernel"]), .nw)
        XCTAssertEqual(VideoSocketKnob.parse(["MATEBRIDGE_VIDEO_SOCKET": ""]), .nw)
    }

    func testNotSentLowatKnob() {
        XCTAssertEqual(NotSentLowatKnob.parseKB([:]), 128)
        XCTAssertEqual(NotSentLowatKnob.parseKB(["MATEBRIDGE_NOTSENT_LOWAT_KB": "64"]), 64)
        XCTAssertEqual(NotSentLowatKnob.parseKB(["MATEBRIDGE_NOTSENT_LOWAT_KB": " 256 "]), 256)
        XCTAssertEqual(NotSentLowatKnob.parseKB(["MATEBRIDGE_NOTSENT_LOWAT_KB": "16"]), 16)
        XCTAssertEqual(NotSentLowatKnob.parseKB(["MATEBRIDGE_NOTSENT_LOWAT_KB": "4096"]), 4096)
        for bad in ["0", "15", "4097", "-1", "abc", "12.5", ""] {
            XCTAssertEqual(NotSentLowatKnob.parseKB(["MATEBRIDGE_NOTSENT_LOWAT_KB": bad]), 128, bad)
        }
    }

    func testVideoSocketSettingsLogFields() {
        XCTAssertEqual(VideoSocketSettings.parse([:]).logFields, "video_socket=nw notsent_lowat_kb=na")
        let bsd = VideoSocketSettings.parse(["MATEBRIDGE_VIDEO_SOCKET": "bsd", "MATEBRIDGE_NOTSENT_LOWAT_KB": "64"])
        XCTAssertEqual(bsd.logFields, "video_socket=bsd notsent_lowat_kb=64")
        XCTAssertEqual(bsd.notSentLowatBytes, 65_536)
        XCTAssertEqual(VideoSocketSettings.parse(["MATEBRIDGE_VIDEO_SOCKET": "bsd"]).logFields,
                       "video_socket=bsd notsent_lowat_kb=128")
    }

    func testNetServiceTypesMatchNetworkFrameworkClasses() {
        XCTAssertEqual(BsdTcpOptions.netServiceType(.interactiveVideo), NET_SERVICE_TYPE_VI)
        XCTAssertEqual(BsdTcpOptions.netServiceType(.interactiveVoice), NET_SERVICE_TYPE_VO)
        XCTAssertEqual(BsdTcpOptions.netServiceType(.responsiveData), NET_SERVICE_TYPE_RD)
        let defaults = BsdTcpOptions()
        XCTAssertTrue(defaults.noDelay)
        XCTAssertFalse(defaults.keepAlive, "NWProtocolTCP.Options leaves keepalive off; so do we")
        XCTAssertNil(defaults.notSentLowatBytes)
    }
}
