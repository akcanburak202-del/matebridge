import Foundation
import Testing
@testable import MateBridgeCore

@Suite struct HostIdentityTests {
    @Test func hostIDIsGeneratedOnceAndStable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostIdentityStore(directory: dir)
        let first = store.loadOrCreate()
        #expect(first.count == 16)
        #expect(store.loadOrCreate() == first)
        #expect(HostIdentityStore(directory: dir).loadOrCreate() == first)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
        // A damaged file is replaced by a fresh id (tablets re-pair); never a short id.
        try Data("not hex".utf8).write(to: store.fileURL)
        let replaced = store.loadOrCreate()
        #expect(replaced.count == 16 && replaced != first)
        #expect(store.loadOrCreate() == replaced)
    }

    @Test func resolveReportsLoadedCreatedAndUnpersisted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mb-id2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = HostIdentityStore(directory: dir)
        guard case .created(let id) = store.resolve() else { Issue.record("expected created"); return }
        #expect(store.resolve() == .loaded(id))
        // A damaged file is a replaced identity: the caller must drop every old approval and key.
        try Data("garbage".utf8).write(to: store.fileURL)
        guard case .created(let again) = store.resolve() else { Issue.record("expected created"); return }
        #expect(again != id)
        #expect(store.resolve() == .loaded(again))
        // Persistence failure (the directory path is a regular file): the id works for this run but is flagged.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("mb-block-\(UUID().uuidString)")
        try Data("x".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        guard case .unpersisted(let volatile) = HostIdentityStore(directory: blocker).resolve() else {
            Issue.record("expected unpersisted"); return
        }
        #expect(volatile.count == 16)
    }

    @Test func videoProofDecoderRejectsAnythingBiggerThanAPing() throws {
        let key = SecretBytes([UInt8](repeating: 3, count: 32))
        var sealer = RecordSealer(key: key, maxPayload: 65_536)
        var decoder = RecordDecoder(key: key, connection: .video, maxPayload: 64)
        decoder.append(try sealer.seal(type: 0x20, payload: [UInt8](repeating: 0, count: 100)))
        #expect(throws: CryptoError.self) { try decoder.nextMessage() }
        var ok = RecordDecoder(key: key, connection: .video, maxPayload: 64)
        var s2 = RecordSealer(key: key, maxPayload: 65_536)
        ok.append(try Message.ping(Ping(seq: 1, senderTimeUs: 2)).sealed(using: &s2))
        #expect(try ok.nextMessage() == .ping(Ping(seq: 1, senderTimeUs: 2)))
    }

    @Test func inMemoryPairKeyStoreBehavesLikeTheKeychainContract() throws {
        let store = InMemoryPairKeyStore()
        let a = DeviceID(bytes: [UInt8](repeating: 1, count: 16))!
        let b = DeviceID(bytes: [UInt8](repeating: 2, count: 16))!
        try store.save(SecretBytes([1]), for: a)
        try store.save(SecretBytes([2]), for: b)
        try store.save(SecretBytes([3]), for: a)  // replaces
        #expect(store.key(for: a) == SecretBytes([3]))
        try store.remove(a)
        #expect(store.key(for: a) == nil && store.key(for: b) != nil)
        try store.removeAll()
        #expect(store.count == 0)
    }
}
