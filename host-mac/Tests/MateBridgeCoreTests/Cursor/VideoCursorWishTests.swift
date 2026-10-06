import Testing
@testable import MateBridgeCore

// The wish behind the video cursor (decision 0036): stale requests, failures and the retry backoff.

@Suite struct VideoCursorWishTests {
    @Test func CURWISH1_theDefaultIsTheCursorInTheVideo() {
        let w = VideoCursorWish()
        #expect(w.wantsCursor)
    }

    @Test func CURWISH2_aHideOfTheLiveSessionIsApplied() {
        var w = VideoCursorWish()
        let hide = w.request(shows: false, generation: w.generation)
        #expect(hide != nil)
        #expect(w.begin(hide!) == true)
        #expect(!w.wantsCursor)
    }

    @Test func CURWISH3_aHideOfAnEndedSessionIsRefusedEvenWhenItArrivesAfterTheReset() {
        var w = VideoCursorWish()
        let oldGeneration = w.generation
        // The session ends (the reset puts the cursor back) while the hide is still on its way.
        let restore = w.reset()
        #expect(w.wantsCursor)
        #expect(w.request(shows: false, generation: oldGeneration) == nil)  // refused when it arrives
        #expect(w.begin(restore) == true)
        #expect(w.wantsCursor)
    }

    @Test func CURWISH4_aHideThatWasAlreadyTicketedBeforeTheResetCannotBeApplied() {
        var w = VideoCursorWish()
        let hide = w.request(shows: false, generation: w.generation)!
        let restore = w.reset()
        #expect(w.begin(hide) == false)  // overtaken and of an old generation
        #expect(w.wantsCursor)
        #expect(w.begin(restore) == true)
        // The next session starts clean and can hide again.
        let next = w.request(shows: false, generation: w.generation)!
        #expect(w.begin(next) == true)
        #expect(!w.wantsCursor)
    }

    @Test func CURWISH5_aNewerRequestOvertakesAnOlderOne() {
        var w = VideoCursorWish()
        let hide = w.request(shows: false, generation: w.generation)!
        let show = w.request(shows: true, generation: w.generation)!
        #expect(w.begin(hide) == false)
        #expect(w.begin(show) == true)
        #expect(w.wantsCursor)
    }

    @Test func CURWISH6_aFailedHideLeavesTheWishOnTheCursorInTheVideoAndIsNotRetried() {
        var w = VideoCursorWish()
        let hide = w.request(shows: false, generation: w.generation)!
        #expect(w.begin(hide) == true)
        #expect(w.failed(hide) == false)
        #expect(w.wantsCursor)  // a capture that restarts now keeps the cursor
    }

    @Test func CURWISH7_aFailedShowKeepsTheWishOnShowAndIsRetried() {
        var w = VideoCursorWish()
        let show = w.reset()
        #expect(w.begin(show) == true)
        #expect(w.failed(show) == true)  // retry it
        #expect(w.wantsCursor)  // a capture that restarts meanwhile starts with the cursor
        let retry = w.retry(after: show)
        #expect(retry != nil)
        #expect(retry!.shows && retry!.epoch > show.epoch)
        #expect(w.begin(retry!) == true)
    }

    @Test func CURWISH8_noRetryOnceSomethingNewerHappened() {
        var w = VideoCursorWish()
        let show = w.reset()
        #expect(w.begin(show) == true)
        #expect(w.failed(show) == true)
        let hide = w.request(shows: false, generation: w.generation)!  // the tablet turned the flow on again
        #expect(w.retry(after: show) == nil)
        #expect(w.begin(hide) == true)
        // A new session end also voids a pending retry.
        _ = w.reset()
        #expect(w.retry(after: show) == nil)
    }

    @Test func CURWISH9_aFailureOfAnOvertakenTicketChangesNothing() {
        var w = VideoCursorWish()
        let hide = w.request(shows: false, generation: w.generation)!
        #expect(w.begin(hide) == true)
        let show = w.request(shows: true, generation: w.generation)!
        #expect(w.failed(hide) == false)
        #expect(w.begin(show) == true)
    }

    @Test func CURWISH10_aRequestOfTheHostItselfIgnoresTheGeneration() {
        var w = VideoCursorWish()
        _ = w.reset()
        _ = w.reset()
        #expect(w.request(shows: true, generation: nil) != nil)
    }

    @Test func CURWISH11_theBackoffDoublesAndIsBounded() {
        let delays = (0..<8).map { VideoCursorWish.retryDelayUs(attempt: $0) }
        #expect(delays == [250_000, 500_000, 1_000_000, 2_000_000, 4_000_000, 8_000_000, 8_000_000, 8_000_000])
        #expect(VideoCursorWish.retryDelayUs(attempt: 1_000) == 8_000_000)
        #expect(VideoCursorWish.retryDelayUs(attempt: -3) == 250_000)
    }
}
