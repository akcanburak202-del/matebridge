import Testing
@testable import MateBridgeCore

@Suite struct HostSleepTests {
    @Test func onlyWillSleepEndsSessions() {
        #expect(HostSleep.endsSessions(.willSleep))
        #expect(!HostSleep.endsSessions(.canSleep))  // may still be cancelled
        #expect(!HostSleep.endsSessions(.willNotSleep))
        #expect(!HostSleep.endsSessions(.didWake))
    }

    @Test func willSleepComesFromTheSystemWillSleepMessage() {
        #expect(PowerEvent.fromIOKitMessage(PowerEvent.systemWillSleepMessage).map(HostSleep.endsSessions) == true)
        #expect(PowerEvent.fromIOKitMessage(PowerEvent.canSystemSleepMessage).map(HostSleep.endsSessions) == false)
    }

    @Test func budgetIsBoundedAndShort() {
        #expect(HostSleep.budgetUs == 300_000)
        #expect(HostSleep.lingerMarginUs < HostSleep.budgetUs)
        #expect(HostSleep.deadlineUs(startUs: 1_000) == 301_000)
    }

    @Test func lingerIsWhatIsLeftMinusTheMargin() {
        let start: UInt64 = 5_000_000
        #expect(HostSleep.lingerUs(startUs: start, nowUs: start) == HostSleep.budgetUs - HostSleep.lingerMarginUs)
        #expect(HostSleep.lingerUs(startUs: start, nowUs: start + 100_000) == 150_000)
        #expect(HostSleep.lingerUs(startUs: start, nowUs: start + 260_000) == 0)  // inside the margin
        #expect(HostSleep.lingerUs(startUs: start, nowUs: start + 400_000) == 0)  // past the deadline
        #expect(HostSleep.lingerUs(startUs: start, nowUs: start - 1) == HostSleep.budgetUs - HostSleep.lingerMarginUs + 1)
    }

    @Test func remainingNeverUnderflows() {
        let start: UInt64 = 10
        #expect(HostSleep.remainingUs(startUs: start, nowUs: start) == HostSleep.budgetUs)
        #expect(HostSleep.remainingUs(startUs: start, nowUs: start + 299_999) == 1)
        #expect(HostSleep.remainingUs(startUs: start, nowUs: start + 300_000) == 0)
        #expect(HostSleep.remainingUs(startUs: start, nowUs: UInt64.max) == 0)
    }
}

@Suite struct HostSleepCutAndProgressTests {
    @Test func cutPointLeavesTheMarginBeforeTheDeadline() {
        #expect(HostSleep.cutDeadlineUs(startUs: 0) == HostSleep.budgetUs - HostSleep.lingerMarginUs)
        #expect(HostSleep.remainingToCutUs(startUs: 100, nowUs: 100) == HostSleep.budgetUs - HostSleep.lingerMarginUs)
        #expect(HostSleep.remainingToCutUs(startUs: 100, nowUs: 100 + 250_000) == 0)
        #expect(HostSleep.remainingToCutUs(startUs: 100, nowUs: UInt64.max) == 0)
        // A connection closed by the sleep lingers exactly until the cut point.
        #expect(HostSleep.lingerUs(startUs: 7, nowUs: 40) == HostSleep.remainingToCutUs(startUs: 7, nowUs: 40))
        #expect(HostSleep.cutDeadlineUs(startUs: 0) < HostSleep.deadlineUs(startUs: 0))
    }

    @Test func progressTracksParticipantsInOrder() {
        var p = HostSleepProgress(names: ["input", "audio"])
        #expect(!p.isComplete)
        #expect(p.logFields == "input=pending audio=pending")
        p.finished("audio")
        p.finished("audio")  // repeat: ignored
        p.finished("video")  // unknown: ignored
        #expect(p.logFields == "input=pending audio=done")
        #expect(!p.isComplete)
        p.finished("input")
        #expect(p.isComplete)
        #expect(p.logFields == "input=done audio=done")
    }

    @Test func progressWithoutParticipantsIsComplete() {
        let p = HostSleepProgress(names: [])
        #expect(p.isComplete)
        #expect(p.logFields.isEmpty)
    }

    @Test func duplicateNamesAreLoggedOnce() {
        var p = HostSleepProgress(names: ["input", "input"])
        #expect(p.logFields == "input=pending")
        p.finished("input")
        #expect(p.isComplete && p.logFields == "input=done")
    }
}
