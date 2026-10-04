import Foundation
import Testing
@testable import MateBridgeCore

struct SingleInstancePolicyTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let poll = SingleInstancePolicy.pollMs
    private let grace = SingleInstancePolicy.graceMs

    private func instance(_ pid: Int32, _ seconds: Double?, terminated: Bool = false) -> SingleInstancePolicy.Instance {
        SingleInstancePolicy.Instance(pid: pid, launchDate: seconds.map { t0.addingTimeInterval($0) },
                                      isTerminated: terminated)
    }

    private func decide(own: Int32 = 200, ownAt: Double? = 10, others: [SingleInstancePolicy.Instance],
                        waited: Int = 0) -> SingleInstancePolicy.Decision {
        SingleInstancePolicy.decide(ownPID: own, ownLaunchDate: ownAt.map { t0.addingTimeInterval($0) },
                                    others: others, waitedMs: waited)
    }

    @Test func aloneProceeds() {
        #expect(decide(others: []) == .proceed)
    }

    @Test func ownPidIsNotCounted() {
        #expect(decide(others: [instance(200, 10)]) == .proceed)
        // Even when the list reports an older launch date for our own pid.
        #expect(decide(others: [instance(200, 0)]) == .proceed)
    }

    @Test func olderLiveCopyBlocksThenExitsAfterGrace() {
        let others = [instance(100, 0)]
        #expect(decide(others: others, waited: 0) == .wait(ms: poll))
        #expect(decide(others: others, waited: grace - 1) == .wait(ms: poll))
        #expect(decide(others: others, waited: grace) == .exit(existingPID: 100))
    }

    @Test func terminatedCopyIsIgnored() {
        #expect(decide(others: [instance(100, 0, terminated: true)]) == .proceed)
    }

    @Test func oldCopyThatQuitsDuringGraceLetsTheNewOneProceed() {
        #expect(decide(others: [instance(100, 0)], waited: 400) == .wait(ms: poll))
        #expect(decide(others: [], waited: 600) == .proceed)
        #expect(decide(others: [instance(100, 0, terminated: true)], waited: 600) == .proceed)
    }

    @Test func youngerCopyDoesNotBlockUs() {
        // The other copy started later: it is the one that yields.
        #expect(decide(others: [instance(300, 20)]) == .proceed)
        #expect(decide(others: [instance(300, 20)], waited: grace) == .proceed)
    }

    @Test func simultaneousStartKeepsExactlyOneCopy() {
        let a = instance(100, 5)
        let b = instance(101, 5)
        let forA = SingleInstancePolicy.decide(ownPID: 100, ownLaunchDate: a.launchDate, others: [a, b], waitedMs: grace)
        let forB = SingleInstancePolicy.decide(ownPID: 101, ownLaunchDate: b.launchDate, others: [a, b], waitedMs: grace)
        #expect(forA == .proceed)
        #expect(forB == .exit(existingPID: 100))
    }

    @Test func unknownLaunchDateFallsBackToPid() {
        #expect(decide(own: 200, ownAt: nil, others: [instance(100, nil)]) == .wait(ms: poll))
        #expect(decide(own: 200, ownAt: nil, others: [instance(300, nil)]) == .proceed)
        #expect(decide(own: 200, ownAt: 10, others: [instance(100, nil)]) == .wait(ms: poll))
    }

    @Test func reportsTheLowestBlockingPid() {
        let others = [instance(150, 1), instance(120, 2)]
        #expect(decide(others: others, waited: grace) == .exit(existingPID: 120))
    }
}
