import Testing
@testable import MateBridgeCore

// MAC-*: which events close something, and their plain form. OWED-*: the store of releases the Mac may not have got.

private let here = DisplayPoint(x: 300, y: 200)

private func buttonUp(_ b: MouseButton, at p: DisplayPoint = here) -> MacEvent { mouseEvent(.up, b, at: p, clickState: 1) }

@Suite("MAC: closing events")
struct MacEventClosingTests {
    @Test("MAC-1 only ups, leaves and scroll ends close something")
    func mac1_isClosing() {
        let closing: [MacEvent] = [
            tabletEvent(.up), proximityEvent(entering: false), buttonUp(.left), buttonUp(.forward),
            scrollEvent(.ended), scrollEvent(.cancelled),
        ]
        let opening: [MacEvent] = [
            tabletEvent(.hover), tabletEvent(.down), tabletEvent(.drag), proximityEvent(entering: true),
            mouseEvent(.moved, at: here), mouseEvent(.dragged, .left, at: here), mouseEvent(.down, at: here, clickState: 1),
            scrollEvent(.began), scrollEvent(.changed), scrollEvent(.none),
        ]
        #expect(closing.allSatisfy { $0.isClosing })
        #expect(opening.allSatisfy { !$0.isClosing })
    }

    @Test("MAC-2 a pen up degrades to a bare left mouse up at the same place; nothing else has a plainer form")
    func mac2_plainRelease() {
        let up = tabletEvent(.up, x: 7, y: 8)
        #expect(up.plainRelease == mouseEvent(.up, .left, at: testGeometry.point(x: 7, y: 8), clickState: 1))
        #expect(proximityEvent(entering: false).plainRelease == nil)
        #expect(buttonUp(.right).plainRelease == nil)
        #expect(scrollEvent(.ended).plainRelease == nil)
        #expect(tabletEvent(.down).plainRelease == nil)
    }

    @Test("MAC-3 placed(on:) keeps a position that is on the display, moves any other to the center, and leaves events without a display alone")
    func mac3_placed() {
        let inside = buttonUp(.left, at: testGeometry.point(x: 100, y: 100))
        #expect(inside.placed(on: testGeometry) == inside)
        let outside = buttonUp(.left, at: DisplayPoint(x: -5000, y: 9000))
        #expect(outside.placed(on: testGeometry) == buttonUp(.left, at: testGeometry.center))
        #expect(outside.placed(on: nil) == outside)
        #expect(proximityEvent(entering: false).placed(on: testGeometry) == proximityEvent(entering: false))
        #expect(scrollEvent(.ended, at: DisplayPoint(x: 1, y: 1)).placed(on: testGeometry) == scrollEvent(.ended, at: testGeometry.center))
    }
}

@Suite("OWED: releases the Mac may not have received")
struct OwedReleaseTests {
    @Test("OWED-1 only closing events are kept, one per slot, the newest wins")
    func owed1_slots() {
        var o = OwedRelease()
        o.owe([proximityEvent(entering: true), tabletEvent(.down), mouseEvent(.moved, at: here), scrollEvent(.changed),
               buttonUp(.right, at: DisplayPoint(x: 1, y: 1)), buttonUp(.right, at: DisplayPoint(x: 2, y: 2))],
              now: 0, countsAsAttempt: false)
        #expect(o.count == 1)
        #expect(o.owedEvents == [buttonUp(.right, at: DisplayPoint(x: 2, y: 2))])
    }

    @Test("OWED-2 they go out in the state machine's release order: pen up, left, leave, other buttons, scroll end")
    func owed2_order() {
        var o = OwedRelease()
        o.owe([scrollEvent(.ended), buttonUp(.back), buttonUp(.right), proximityEvent(entering: false), buttonUp(.left),
               tabletEvent(.up)], now: 0, countsAsAttempt: false)
        let events = o.replay(now: 0, force: true, geometry: nil)
        #expect(events == [tabletEvent(.up), buttonUp(.left), proximityEvent(entering: false), buttonUp(.right),
                           buttonUp(.back), scrollEvent(.ended)])
        #expect(o.isEmpty)
    }

    @Test("OWED-3 replayed events are positioned on the display of the moment")
    func owed3_positions() {
        var o = OwedRelease()
        o.owe([buttonUp(.left, at: DisplayPoint(x: 99_999, y: 99_999)), buttonUp(.right, at: testGeometry.point(x: 5, y: 5))],
              now: 0, countsAsAttempt: false)
        let events = o.replay(now: 0, force: true, geometry: testGeometry)
        #expect(events == [buttonUp(.left, at: testGeometry.center), buttonUp(.right, at: testGeometry.point(x: 5, y: 5))])
    }

    @Test("OWED-4 a failed post is retried after the interval (inclusive), a forced replay ignores it")
    func owed4_spacing() {
        var o = OwedRelease()
        o.owe([buttonUp(.left)], now: 1_000_000, countsAsAttempt: true)
        #expect(o.replay(now: 1_249_999, force: false, geometry: nil).isEmpty)
        #expect(o.replay(now: 1_250_000, force: false, geometry: nil) == [buttonUp(.left)])

        var f = OwedRelease()
        f.owe([buttonUp(.left)], now: 1_000_000, countsAsAttempt: true)
        #expect(f.replay(now: 1_000_001, force: true, geometry: nil) == [buttonUp(.left)])
    }

    @Test("OWED-5 an owed release is never given up on: it survives far more failed attempts than the cadence steps, and is posted once posting recovers")
    func owed5_neverGivenUp() {
        var o = OwedRelease()
        var t: UInt64 = 0
        o.owe([buttonUp(.left), tabletEvent(.up)], now: t, countsAsAttempt: true)
        var replays = 0
        for _ in 0..<200 {  // far more than the six normal attempts
            t += OwedRelease.slowIntervalUs
            let r = o.replay(now: t, force: false, geometry: nil)
            if !r.isEmpty {
                replays += 1
                o.owe(r, now: t, countsAsAttempt: true)  // building the event failed again
            }
        }
        #expect(replays == 200 && o.count == 2)  // still both there, still tried every second
        t += OwedRelease.slowIntervalUs
        let last = o.replay(now: t, force: false, geometry: nil)  // creation recovered: not reported failed
        #expect(last == [tabletEvent(.up), buttonUp(.left)])
        #expect(o.isEmpty)
    }

    @Test("OWED-6 the retry cadence: 250 ms for the first six replays, then once a second; the drop is counted once per slot")
    func owed6_cadence() {
        var o = OwedRelease()
        var t: UInt64 = 0
        o.owe([buttonUp(.left)], now: t, countsAsAttempt: true)
        var times: [UInt64] = []
        for _ in 0..<9 {
            // Wait for the entry to become due.
            var r: [MacEvent] = []
            while r.isEmpty {
                t += 50_000
                r = o.replay(now: t, force: false, geometry: nil)
            }
            times.append(t)
            o.owe(r, now: t, countsAsAttempt: true)
        }
        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }
        #expect(gaps[0..<5].allSatisfy { $0 == OwedRelease.retryIntervalUs })  // replays 1-6
        #expect(gaps[5...].allSatisfy { $0 == OwedRelease.slowIntervalUs })    // from the sixth failure on
        #expect(o.slowed == 1)
        // A different slot crossing later counts separately.
        o.owe([tabletEvent(.up)], now: t, countsAsAttempt: true)
        for _ in 0..<OwedRelease.slowAfterAttempts {
            t += OwedRelease.slowIntervalUs
            o.owe(o.replay(now: t, force: true, geometry: nil).filter { $0 == tabletEvent(.up) }, now: t, countsAsAttempt: true)
        }
        #expect(o.slowed == 2)
    }

    @Test("OWED-7 waiting for a missing permission costs no attempt, however long it takes")
    func owed7_permissionWaitIsFree() {
        var o = OwedRelease()
        o.owe([buttonUp(.left), tabletEvent(.up)], now: 0, countsAsAttempt: false)
        for _ in 0..<50 {
            let r = o.replay(now: 0, force: true, geometry: nil)
            #expect(r.count == 2)
            o.owe(r, now: 0, countsAsAttempt: false)  // refused again: the permission is still gone
        }
        #expect(o.slowed == 0 && o.count == 2)
        // ...and the normal cadence applies once the poster is the problem.
        let r = o.replay(now: 0, force: true, geometry: nil)
        o.owe(r, now: 10, countsAsAttempt: true)
        #expect(o.replay(now: 10 + OwedRelease.retryIntervalUs - 1, force: false, geometry: nil).isEmpty)
        #expect(o.replay(now: 10 + OwedRelease.retryIntervalUs, force: false, geometry: nil).count == 2)
    }

    @Test("OWED-8 a replay that is not reported failed is forgotten once confirmed; until then it blocks")
    func owed8_confirmation() {
        var o = OwedRelease()
        o.owe([buttonUp(.left)], now: 0, countsAsAttempt: false)
        #expect(o.isBlocking)
        #expect(o.replay(now: 0, force: true, geometry: nil).count == 1)
        #expect(o.isEmpty && o.isBlocking)  // handed out, not yet confirmed
        o.confirmPosted()
        #expect(!o.isBlocking)
        #expect(o.replay(now: 10, force: true, geometry: nil).isEmpty)
        // A failure report after confirmation is a new failure: it starts from zero attempts.
        o.owe([buttonUp(.left)], now: 20, countsAsAttempt: true)
        #expect(o.count == 1 && o.slowed == 0 && o.isBlocking)
    }

    @Test("OWED-9 an entry leaves the store only by being posted or by a newer closing event for the same slot")
    func owed9_supersede() {
        var o = OwedRelease()
        o.owe([buttonUp(.left, at: DisplayPoint(x: 1, y: 1))], now: 0, countsAsAttempt: true)
        o.owe([buttonUp(.left, at: DisplayPoint(x: 2, y: 2))], now: 5, countsAsAttempt: true)
        #expect(o.count == 1 && o.owedEvents == [buttonUp(.left, at: DisplayPoint(x: 2, y: 2))])
        o.owe([mouseEvent(.down, at: here, clickState: 1), tabletEvent(.down), proximityEvent(entering: true)], now: 9, countsAsAttempt: true)
        #expect(o.count == 1)  // opening events never touch the store
        #expect(o.nextRetryAt == 5 + OwedRelease.retryIntervalUs)
    }

    @Test("OWED-10 a pen leave is never replayed before the pen up it depends on")
    func owed10_leaveAfterUp() {
        var o = OwedRelease()
        o.owe([tabletEvent(.up)], now: 1_000_000, countsAsAttempt: true)   // the up failed and waits for its retry
        o.owe([proximityEvent(entering: false)], now: 0, countsAsAttempt: false)  // the leave, held back, is due at once
        #expect(o.owesPenUp)
        #expect(o.replay(now: 1_100_000, force: false, geometry: nil).isEmpty)  // the up is not due: neither is the leave
        #expect(o.replay(now: 1_250_000, force: false, geometry: nil) == [tabletEvent(.up), proximityEvent(entering: false)])
        // A leave on its own (its up was posted) is due at once.
        var l = OwedRelease()
        l.owe([proximityEvent(entering: false)], now: 0, countsAsAttempt: false)
        #expect(l.replay(now: 0, force: false, geometry: nil) == [proximityEvent(entering: false)])
    }
}
