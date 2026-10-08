import Testing
@testable import MateBridgeCore

/// T-308: a wake job queued for an earlier sleep must not clear a newer sleep's gate.
@Suite struct HostSleepGateGenerationTests {
    @Test func staleWakeLeavesNewerSleepGateClosed() {
        var gate = HostSleepInputGate()
        gate.set(awakeNs: 1_000)
        let first = gate.generation
        gate.set(awakeNs: 2_000)  // second sleep before the queued wake ran
        #expect(gate.generation != first)
        let cleared = gate.wake(ifGeneration: first)
        #expect(!cleared)
        #expect(gate.isClosed(atAwakeNs: 3_000))
    }

    @Test func matchingWakeClears() {
        var gate = HostSleepInputGate()
        gate.set(awakeNs: 1_000)
        let cleared = gate.wake(ifGeneration: gate.generation)
        #expect(cleared)
        #expect(!gate.isSet)
    }

    @Test func wakeThenNewSleepThenStaleWake() {
        var gate = HostSleepInputGate()
        gate.set(awakeNs: 1_000)
        let first = gate.generation
        let woke = gate.wake(ifGeneration: first)
        #expect(woke)
        gate.set(awakeNs: 5_000)
        let cleared = gate.wake(ifGeneration: first)
        #expect(!cleared)
        #expect(gate.isSet)
    }
}
