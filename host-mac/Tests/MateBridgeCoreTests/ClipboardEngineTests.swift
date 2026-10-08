import Foundation
import Testing
@testable import MateBridgeCore

private final class FakePasteboard: PasteboardAccess, @unchecked Sendable {
    let lock = NSLock()
    var count = 1
    var text: String?
    var concealed = false
    var stringReads = 0
    /// Runs inside `isConcealed` / `string` reads to simulate the pasteboard changing mid-snapshot.
    var onRead: (() -> Void)?

    var changeCount: Int { lock.withLock { count } }
    var isConcealed: Bool { onRead?(); return concealed }
    var string: String? { stringReads += 1; onRead?(); return text }
    func write(_ t: String) -> Int { lock.withLock { count += 1; text = t; concealed = false; return count } }
    func copy(_ t: String?, concealed: Bool = false) { lock.withLock { count += 1; text = t; self.concealed = concealed } }
}

@Suite struct ClipboardEngineTests {
    @Test func plainCopyIsSent() {
        let pb = FakePasteboard()
        var e = ClipboardEngine(pasteboard: pb, enabled: true)
        e.begin()
        pb.copy("hello")
        #expect(e.poll() == .send(.text(seq: 0, "hello")))
        #expect(e.poll() == .nothing)
    }

    @Test func concealedContentIsNotReadAtAll() {
        let pb = FakePasteboard()
        var e = ClipboardEngine(pasteboard: pb, enabled: true)
        e.begin()
        pb.copy("hunter2", concealed: true)
        #expect(e.poll() == .nothing)
        #expect(pb.stringReads == 0)
    }

    @Test func changeMidReadSendsNothingAndIsRetried() {
        let pb = FakePasteboard()
        var e = ClipboardEngine(pasteboard: pb, enabled: true)
        e.begin()
        pb.copy("plain")
        // Between the marker read and the string read a password manager replaces the content.
        pb.onRead = { [unowned pb] in
            pb.onRead = nil
            pb.copy("hunter2", concealed: true)
        }
        #expect(e.poll() == .nothing)
        // Next poll sees the new (concealed) content consistently: still nothing is sent.
        #expect(e.poll() == .nothing)
        #expect(pb.concealed)
        // A later ordinary copy goes out.
        pb.copy("next")
        #expect(e.poll() == .send(.text(seq: 0, "next")))
    }

    @Test func incomingWriteIsNotEchoed() {
        let pb = FakePasteboard()
        var e = ClipboardEngine(pasteboard: pb, enabled: true)
        e.begin()
        #expect(e.applyIncoming(.text(seq: 1, "from tablet")) == 11)
        #expect(pb.text == "from tablet")
        #expect(e.poll() == .nothing)
    }
}
