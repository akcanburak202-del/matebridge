import Foundation
import Testing
@testable import MateBridgeCore

@Suite struct SessionSupportTests {
    @Test func logLineFollowsLoggingDoc() {
        let s = LogFormat.line(monoMs: 1234, level: .info, component: "session", sessionID: 7, generation: 2,
                               event: "connect_ok", fields: "port=5")
        #expect(s == "1234 I session sid=7 gen=2 ev=connect_ok port=5")
        #expect(LogFormat.line(monoMs: 1, level: .warning, component: "net", sessionID: 0, generation: 0,
                               event: "x") == "1 W net sid=0 gen=0 ev=x")
    }

    @Test func storeRoundTripsAndFailsClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ApprovedDeviceStore(directory: dir)
        #expect(store.load().isEmpty)  // missing file
        let a = DeviceID(bytes: (0..<16).map { UInt8($0) })!
        try store.save([a: "Pad"])
        #expect(store.load() == [a: "Pad"])
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        try Data("garbage".utf8).write(to: store.fileURL)
        #expect(store.load().isEmpty)
        try store.save([:])
        #expect(store.load().isEmpty)
    }
}
