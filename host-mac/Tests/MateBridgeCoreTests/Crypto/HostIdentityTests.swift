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
