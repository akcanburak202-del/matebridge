import Testing
@testable import MateBridgeCore

/// Drives `LoginItemPolicy` the way `LoginItem` does, against an in-memory flag and a fake `SMAppService`.
private struct FakeLoginItem {
    var firstRunDone = false
    var status: LoginItemStatus = .off
    var bundled = true
    /// Result of the next register/unregister call; nil = it succeeds.
    var nextFailure: String?
    var problem: String?
    var calls: [LoginItemPolicy.Action] = []

    mutating func launch() { run(.launch) }
    mutating func toggle() { run(.userToggle) }

    private mutating func run(_ trigger: LoginItemPolicy.Trigger) {
        let action = LoginItemPolicy.action(for: trigger, firstRunDone: firstRunDone, status: bundled ? status : .off)
        let outcome = perform(action)
        problem = LoginItemPolicy.problem(after: outcome)
        if LoginItemPolicy.marksDone(trigger: trigger, action: action, outcome: outcome) { firstRunDone = true }
    }

    private mutating func perform(_ action: LoginItemPolicy.Action) -> LoginItemPolicy.Outcome {
        if action == .none { return .succeeded }
        guard bundled else { return .notBundled }
        calls.append(action)
        if let reason = nextFailure {
            nextFailure = nil
            return .failed(reason: reason)
        }
        status = action == .register ? .enabled : .off
        return .succeeded
    }
}

@Suite struct LoginItemPolicyTests {
    @Test func firstRunSuccessRegistersAndMarksDone() {
        var item = FakeLoginItem()
        item.launch()
        #expect(item.calls == [.register])
        #expect(item.status == .enabled)
        #expect(item.firstRunDone)
        #expect(item.problem == nil)
    }

    /// M06: the flag used to be written before the registration, so one failure meant no retry ever.
    @Test func failedFirstRunIsRetriedOnTheNextLaunch() {
        var item = FakeLoginItem(nextFailure: "boom")
        item.launch()
        #expect(item.calls == [.register])
        #expect(!item.firstRunDone)
        #expect(item.problem == "Oturum açılışı ayarlanamadı: boom")

        item.problem = nil  // a new process starts without the in-memory problem
        item.nextFailure = "again"
        item.launch()
        #expect(item.calls == [.register, .register])
        #expect(!item.firstRunDone)
        #expect(item.problem == "Oturum açılışı ayarlanamadı: again")

        item.launch()
        #expect(item.calls == [.register, .register, .register])
        #expect(item.status == .enabled)
        #expect(item.firstRunDone)
        #expect(item.problem == nil)

        item.launch()  // done: no further registration
        #expect(item.calls.count == 3)
    }

    @Test func userToggledOffIsNeverAutoRegisteredAgain() {
        var item = FakeLoginItem()
        item.launch()
        item.toggle()
        #expect(item.calls == [.register, .unregister])
        #expect(item.status == .off)
        #expect(item.firstRunDone)
        for _ in 0..<3 { item.launch() }
        #expect(item.calls == [.register, .unregister])
    }

    @Test func userToggledOffWinsEvenWhenUnregisterFails() {
        var item = FakeLoginItem(status: .requiresApproval, nextFailure: "denied")
        item.toggle()
        #expect(item.calls == [.unregister])
        #expect(item.firstRunDone)
        #expect(item.problem == "Oturum açılışı ayarlanamadı: denied")
        item.status = .off  // e.g. the user then removes it in System Settings
        item.launch()
        #expect(item.calls == [.unregister])
    }

    @Test func userToggledOnAfterAFailedFirstRunMarksDone() {
        var item = FakeLoginItem(nextFailure: "boom")
        item.launch()
        #expect(!item.firstRunDone)
        item.toggle()
        #expect(item.calls == [.register, .register])
        #expect(item.status == .enabled)
        #expect(item.firstRunDone)
        #expect(item.problem == nil)
    }

    @Test func failedToggleOnIsRetriedOnTheNextLaunch() {
        var item = FakeLoginItem(nextFailure: "boom")
        item.launch()
        item.nextFailure = "still"
        item.toggle()
        #expect(!item.firstRunDone)
        #expect(item.problem == "Oturum açılışı ayarlanamadı: still")
        item.launch()
        #expect(item.calls == [.register, .register, .register])
        #expect(item.firstRunDone)
    }

    @Test func notBundledPersistsNothing() {
        var item = FakeLoginItem(bundled: false)
        item.launch()
        #expect(!item.firstRunDone)
        #expect(item.problem == "Oturum açılışı yalnız MateBridge.app ile çalışır")
        item.toggle()
        #expect(!item.firstRunDone)
        #expect(item.calls.isEmpty)
    }

    @Test func alreadyRequestedAtFirstLaunchIsNotRegisteredAgain() {
        for status in [LoginItemStatus.enabled, .requiresApproval] {
            var item = FakeLoginItem(status: status)
            item.launch()
            #expect(item.calls.isEmpty)
            #expect(item.firstRunDone)
            #expect(item.problem == nil)
        }
    }

    @Test func actionTable() {
        typealias P = LoginItemPolicy
        #expect(P.action(for: .launch, firstRunDone: true, status: .off) == .none)
        #expect(P.action(for: .launch, firstRunDone: false, status: .off) == .register)
        #expect(P.action(for: .launch, firstRunDone: false, status: .enabled) == .none)
        #expect(P.action(for: .userToggle, firstRunDone: true, status: .off) == .register)
        #expect(P.action(for: .userToggle, firstRunDone: false, status: .requiresApproval) == .unregister)
        #expect(P.action(for: .userToggle, firstRunDone: true, status: .enabled) == .unregister)
    }
}
