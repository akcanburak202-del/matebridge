import Testing
@testable import MateBridgeCore

@Suite struct ClipboardSyncTests {
    private func started(_ cc: Int = 10, enabled: Bool = true) -> ClipboardSync {
        var s = ClipboardSync(enabled: enabled)
        s.begin(changeCount: cc)
        return s
    }

    @Test func existingClipboardIsNotSentAtStart() {
        var s = started()
        #expect(s.observe(changeCount: 10, text: "old", isConcealed: false) == .nothing)
    }

    @Test func nothingBeforeBegin() {
        var s = ClipboardSync()
        #expect(s.observe(changeCount: 5, text: "x", isConcealed: false) == .nothing)
    }

    @Test func newTextIsSentOnceWithIncreasingSeq() {
        var s = started()
        #expect(s.observe(changeCount: 11, text: "a", isConcealed: false) == .send(.text(seq: 0, "a")))
        #expect(s.observe(changeCount: 11, text: "a", isConcealed: false) == .nothing)
        #expect(s.observe(changeCount: 12, text: "b", isConcealed: false) == .send(.text(seq: 1, "b")))
    }

    @Test func nonTextChangeSendsEmpty() {
        var s = started()
        #expect(s.observe(changeCount: 11, text: nil, isConcealed: false) == .send(.empty(seq: 0)))
        #expect(s.observe(changeCount: 12, text: "", isConcealed: false) == .send(.empty(seq: 1)))
    }

    @Test func concealedIsNeverSentAndNotResentLater() {
        var s = started()
        #expect(s.observe(changeCount: 11, text: "secret", isConcealed: true) == .nothing)
        #expect(s.observe(changeCount: 11, text: "secret", isConcealed: false) == .nothing)
    }

    @Test func limitBoundary() {
        var s = started()
        let ok = String(repeating: "a", count: 60_000)
        #expect(s.observe(changeCount: 11, text: ok, isConcealed: false) == .send(.text(seq: 0, ok)))
        let big = ok + "a"
        #expect(s.observe(changeCount: 12, text: big, isConcealed: false) == .tooLarge(bytes: 60_001))
        #expect(s.observe(changeCount: 12, text: big, isConcealed: false) == .nothing)  // once
    }

    @Test func limitCountsBytesNotCharacters() {
        var s = started()
        let t = String(repeating: "ş", count: 30_001)  // 60 002 bytes
        #expect(s.observe(changeCount: 11, text: t, isConcealed: false) == .tooLarge(bytes: 60_002))
    }

    @Test func receivedTextIsWrittenAndNotEchoed() {
        var s = started()
        #expect(s.receive(.text(seq: 9, "from tablet")) == "from tablet")
        s.didWrite(changeCount: 11)
        #expect(s.observe(changeCount: 11, text: "from tablet", isConcealed: false) == .nothing)
        // The same text appearing under a new changeCount is still suppressed by its digest.
        #expect(s.observe(changeCount: 12, text: "from tablet", isConcealed: false) == .nothing)
        // Different text goes out.
        #expect(s.observe(changeCount: 13, text: "mine", isConcealed: false) == .send(.text(seq: 0, "mine")))
    }

    @Test func receiveIgnoresEmptyUnknownKindInvalidUtf8AndOversize() {
        var s = started()
        #expect(s.receive(.empty(seq: 1)) == nil)
        #expect(s.receive(Clipboard(seq: 1, kind: 7, data: Array("x".utf8))) == nil)
        #expect(s.receive(Clipboard(seq: 1, kind: 1, data: [0xff, 0xfe])) == nil)
        #expect(s.receive(Clipboard(seq: 1, kind: 1, data: [])) == nil)
        #expect(s.receive(Clipboard(seq: 1, kind: 1, data: [UInt8](repeating: 0x61, count: 60_001))) == nil)
    }

    @Test func disabledIgnoresBothDirectionsAndReenableDoesNotSendOld() {
        var s = started(enabled: false)
        #expect(s.observe(changeCount: 11, text: "a", isConcealed: false) == .nothing)
        #expect(s.receive(.text(seq: 1, "x")) == nil)
        s.setEnabled(true, changeCount: 11)
        #expect(s.observe(changeCount: 11, text: "a", isConcealed: false) == .nothing)
        #expect(s.observe(changeCount: 12, text: "b", isConcealed: false) == .send(.text(seq: 0, "b")))
    }

    @Test func endStopsEverything() {
        var s = started()
        s.end()
        #expect(s.observe(changeCount: 11, text: "a", isConcealed: false) == .nothing)
        #expect(s.receive(.text(seq: 1, "x")) == nil)
    }

    @Test func oversizeClipboardCannotBeEncoded() {
        let m = Message.clipboard(Clipboard(seq: 0, kind: 1, data: [UInt8](repeating: 0x61, count: 60_001)))
        #expect(throws: ProtocolError.self) { try m.encode() }
    }
}
