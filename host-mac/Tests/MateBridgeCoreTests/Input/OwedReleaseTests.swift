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
        let events = o.replay(now: 0, force: true, geometry: nil).events
        #expect(events == [tabletEvent(.up), buttonUp(.left), proximityEvent(entering: false), buttonUp(.right),
                           buttonUp(.back), scrollEvent(.ended)])
        #expect(o.isEmpty)
    }

    @Test("OWED-3 replayed events are positioned on the display of the moment")
    func owed3_positions() {
        var o = OwedRelease()
        o.owe([buttonUp(.left, at: DisplayPoint(x: 99_999, y: 99_999)), buttonUp(.right, at: testGeometry.point(x: 5, y: 5))],
              now: 0, countsAsAttempt: false)
        let events = o.replay(now: 0, force: true, geometry: testGeometry).events
        #expect(events == [buttonUp(.left, at: testGeometry.center), buttonUp(.right, at: testGeometry.point(x: 5, y: 5))])
    }

    @Test("OWED-4 a failed post is retried after the interval (inclusive), a forced replay ignores it")
    func owed4_spacing() {
        var o = OwedRelease()
        o.owe([buttonUp(.left)], now: 1_000_000, countsAsAttempt: true)
        #expect(o.replay(now: 1_249_999, force: false, geometry: nil).events.isEmpty)
        #expect(o.replay(now: 1_250_000, force: false, geometry: nil).events == [buttonUp(.left)])

        var f = OwedRelease()
        f.owe([buttonUp(.left)], now: 1_000_000, countsAsAttempt: true)
        #expect(f.replay(now: 1_000_001, force: true, geometry: nil).events == [buttonUp(.left)])
    }

    @Test("OWED-5 retries are bounded: six replays, each reported failed, then the seventh gives up")
    func owed5_bounded() {
        var o = OwedRelease()
        var t: UInt64 = 0
        o.owe([buttonUp(.left)], now: t, countsAsAttempt: true)
        var replays = 0
        for _ in 0..<40 {
            t += 300_000
            let r = o.replay(now: t, force: false, geometry: nil)
            if !r.events.isEmpty {
                replays += 1
                o.owe(r.events, now: t, countsAsAttempt: true)
            } else if r.gaveUp > 0 {
                break
            }
        }
        #expect(replays == OwedRelease.maxAttempts)
        #expect(o.gaveUp == 1 && o.isEmpty)
    }

    @Test("OWED-6 waiting for a missing permission costs no attempt, however long it takes")
    func owed6_permissionWaitIsFree() {
        var o = OwedRelease()
        o.owe([buttonUp(.left), tabletEvent(.up)], now: 0, countsAsAttempt: false)
        for _ in 0..<50 {
            let r = o.replay(now: 0, force: true, geometry: nil)
            #expect(r.events.count == 2)
            o.owe(r.events, now: 0, countsAsAttempt: false)  // refused again: the permission is still gone
        }
        #expect(o.gaveUp == 0 && o.count == 2)
    }

    @Test("OWED-7 a replay that is not reported failed is forgotten")
    func owed7_successIsForgotten() {
        var o = OwedRelease()
        o.owe([buttonUp(.left)], now: 0, countsAsAttempt: false)
        #expect(o.replay(now: 0, force: true, geometry: nil).events.count == 1)
        #expect(o.isEmpty)
        #expect(o.replay(now: 10, force: true, geometry: nil).events.isEmpty)
        // A fresh failure for the same slot after that starts from zero attempts.
        o.owe([buttonUp(.left)], now: 20, countsAsAttempt: true)
        #expect(o.count == 1 && o.gaveUp == 0)
    }
}
