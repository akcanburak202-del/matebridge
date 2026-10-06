import Testing
@testable import MateBridgeCore

// The video cursor reconciler (decision 0036): one desire, latest wins; the loop only ever compares and changes.

private typealias R = VideoCursorReconciler

private func outcome(_ g: Int, _ shows: Bool, _ ok: Bool) -> R.Outcome { R.Outcome(generation: g, shows: shows, ok: ok) }

@Suite struct VideoCursorReconcilerTests {
    @Test func CURREC1_theDefaultDesireIsTheCursorInTheVideo() {
        var r = R()
        #expect(r.desiredShows)
        #expect(r.plan(actualShows: true) == .done(nil))
        #expect(r.plan(actualShows: nil) == .done(nil))
    }

    @Test func CURREC2_aRequestIsAppliedThenReportedOnce() {
        var r = R()
        #expect(r.request(shows: false, generation: r.generation) == true)
        #expect(r.plan(actualShows: true) == .apply(shows: false))
        r.succeeded()
        #expect(r.plan(actualShows: false) == .done(outcome(0, false, true)))
        #expect(r.plan(actualShows: false) == .done(nil))  // told once
    }

    @Test func CURREC3_aRequestWithNoCaptureIsDoneAtOnce() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        #expect(r.plan(actualShows: nil) == .done(outcome(0, false, true)))
        #expect(!r.desiredShows)  // a capture that starts later starts hidden
    }

    @Test func CURREC4_aRequestOfAnEndedSessionIsIgnored() {
        var r = R()
        let old = r.generation
        r.reset()
        #expect(r.request(shows: false, generation: old) == false)
        #expect(r.desiredShows)
        #expect(r.plan(actualShows: true) == .done(nil))
    }

    @Test func CURREC5_resetPutsTheCursorBackAndVoidsWhatWaited() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        r.reset()
        #expect(r.desiredShows && r.generation == 1)
        #expect(r.plan(actualShows: false) == .apply(shows: true))  // a hidden capture is brought back
        r.succeeded()
        #expect(r.plan(actualShows: true) == .done(nil))  // nobody waits for the old request's outcome
        // The next session starts clean.
        #expect(r.request(shows: false, generation: 1) == true)
    }

    @Test func CURREC6_aReplacementCaptureIsBroughtInLineWithTheSameDesire() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        _ = r.plan(actualShows: false)  // capture A has it
        r.captureChanged()
        #expect(r.plan(actualShows: true) == .apply(shows: false))  // capture B came up with the cursor
        r.succeeded()
        #expect(r.plan(actualShows: false) == .done(nil))
    }

    @Test func CURREC7_aRefusalIsReportedOnceAndRetriedWithABoundedBackoff() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        var delays: [UInt64] = []
        var reports: [R.Outcome] = []
        for _ in 0..<8 {
            #expect(r.plan(actualShows: true) == .apply(shows: false))
            let f = r.failed(attempted: false, onCurrentCapture: true)
            delays.append(f.delayUs)
            if let o = f.outcome { reports.append(o) }
        }
        #expect(reports == [outcome(0, false, false)])
        #expect(delays == [250_000, 500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000, 8_000_000, 8_000_000])
        #expect(!r.desiredShows)  // a refusal does not change the desire; the host decides what it means
    }

    @Test func CURREC8_aNewDesireRestartsTheBackoffAndTheReport() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        _ = r.failed(attempted: false, onCurrentCapture: true)
        _ = r.failed(attempted: false, onCurrentCapture: true)
        _ = r.request(shows: true, generation: 0)  // the host asks the cursor back
        let f = r.failed(attempted: true, onCurrentCapture: true)
        #expect(f.delayUs == 250_000)
        #expect(f.outcome == outcome(0, true, false))
    }

    @Test func CURREC9_aRefusalOfAnOutdatedChangeOrAReplacedCaptureDoesNothing() {
        var r = R()
        _ = r.request(shows: false, generation: 0)
        // The desire moved on while the hide was running.
        _ = r.request(shows: true, generation: 0)
        let stale = r.failed(attempted: false, onCurrentCapture: true)
        #expect(stale.outcome == nil && stale.delayUs == 0)
        // Capture A refused, but B is the running one: no report, no backoff, plan again.
        let f = r.failed(attempted: true, onCurrentCapture: false)
        #expect(f.outcome == nil && f.delayUs == 0)
    }

    @Test func CURREC10_aHideThatFailedOnAIsRestoredOnBWhenTheHostAsksTheCursorBack() {
        // The finding: A's hide refused after B (already hidden) attached.
        var r = R()
        _ = r.request(shows: false, generation: 0)
        r.captureChanged()  // B attached, hidden
        let late = r.failed(attempted: false, onCurrentCapture: false)  // A's refusal arrives
        #expect(late.outcome == nil)
        #expect(r.plan(actualShows: false) == .done(outcome(0, false, true)))  // B is consistent with the desire
        // Later the host gives up the hide (a refusal on B, say) and asks the cursor back: B is restored.
        _ = r.request(shows: true, generation: 0)
        #expect(r.plan(actualShows: false) == .apply(shows: true))
    }

    @Test func CURREC11_theRetryBackoffIsBounded() {
        #expect(R.retryDelayUs(attempt: 1_000) == 8_000_000)
        #expect(R.retryDelayUs(attempt: -3) == 250_000)
    }

    @Test func CURREC12_aRefusedShowStaysTheDesireAndKeepsRetrying() {
        var r = R()
        r.reset()
        var last: UInt64 = 0
        for i in 0..<10 {
            #expect(r.plan(actualShows: false) == .apply(shows: true))
            let f = r.failed(attempted: true, onCurrentCapture: true)
            #expect(f.delayUs >= last)
            last = f.delayUs
            if i > 0 { #expect(f.outcome == nil) }
        }
        #expect(r.desiredShows)
    }
}
