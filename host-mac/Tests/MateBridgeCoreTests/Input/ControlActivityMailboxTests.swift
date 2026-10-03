import Testing
@testable import MateBridgeCore

// MBOX-*: KEY-REPEAT-STALL through the Host's coalescing path (`ControlActivityMailbox`, T-163): the session queue
// notes every record of the active control connection, the input queue hands the coalesced activity to the machine
// only at its own entry points (timer, 1 s poll, messages, the gap wake-up).

private func macDefaults() -> InputStateMachine.Configuration {
    var c = InputStateMachine.Configuration()
    c.keyRepeatDelayUs = 500 * msec
    c.keyRepeatIntervalUs = 83 * msec
    return c
}

/// The Host's input side, 1 ms at a time, with a real one-shot timer: it is armed only where `InputController` re-arms
/// it (after every entry point), at `nextDeadline`, and the re-arm tells the mailbox whether the repeat is parked. The
/// timer and the 1 s poll hand the mailbox off before ticking; a requested wake-up runs when asked (`InputController`
/// queues it: there it runs right after the current entry point, which is the same here because notes only come
/// between entry points).
private struct MailboxHost {
    var d: Driver
    var mailbox: ControlActivityMailbox
    var nextPoll: UInt64
    var timerAt: UInt64?
    var lastNote: UInt64?
    var repeatTimes: [UInt64] = []
    var wakes = 0
    /// Repeats that came out more than the stall pause after the last noted record (must stay empty).
    var staleRepeats: [UInt64] = []

    init(configuration: InputStateMachine.Configuration) {
        d = Driver(configuration: configuration)
        mailbox = ControlActivityMailbox(stallGapUs: configuration.keyRepeatStallPauseUs)
        nextPoll = d.now + 1_000 * msec
    }

    /// `InputController.rearmWatchdog`.
    mutating func rearm() {
        timerAt = d.machine.nextDeadline(now: d.now)
        if mailbox.setRepeatParked(d.machine.isKeyRepeatPaused(at: d.now)) { wake() }
    }

    mutating func wake() {
        wakes += 1
        if let h = mailbox.takeForWake() { d.machine.noteControlActivity(h) }
        rearm()
    }

    /// A record of the active session received at `time` (default: now), noted after it was handled.
    mutating func note(receivedAt time: UInt64? = nil) {
        let t = time ?? d.now
        if mailbox.note(t) { wake() }
        lastNote = t
    }

    mutating func handOff() {
        if let h = mailbox.take() { d.machine.noteControlActivity(h) }
    }

    /// A delivered message received now: hand-off first, then the message; handling takes `processing`, then the
    /// re-arm, then the session queue notes the record's receive time.
    @discardableResult
    mutating func deliver(_ message: Message, processing: UInt64 = 0) -> [InjectAction] {
        let receivedAt = d.now
        handOff()
        let out = d.machine.handle(message, now: d.now)
        record(out)
        d.now += processing
        rearm()
        note(receivedAt: receivedAt)
        return out
    }

    mutating func record(_ out: [InjectAction]) {
        for case .keyDown(_, true) in out {
            repeatTimes.append(d.now)
            if let last = lastNote, d.now - last > d.machine.configuration.keyRepeatStallPauseUs {
                staleRepeats.append(d.now)
            }
        }
    }

    /// Advances 1 ms at a time for `duration`; a record every `noteEvery` (nil: silence).
    mutating func run(for duration: UInt64, noteEvery: UInt64?) {
        let end = d.now + duration
        while d.now < end {
            d.now += 1 * msec
            if let every = noteEvery, d.now % every == 0 { note() }
            let timerDue = timerAt.map { d.now >= $0 } ?? false
            let pollDue = d.now >= nextPoll
            if pollDue { nextPoll += 1_000 * msec }
            if timerDue || pollDue {
                handOff()
                record(d.machine.tick(now: d.now))
                rearm()
            }
        }
    }
}

@Suite("MBOX: KEY-REPEAT-STALL through the Host's coalescing mailbox")
struct ControlActivityMailboxTests {
    @Test("MBOX-1 records every 500 ms handed off only every 1 s: no pause and no postponed repeat")
    func mbox1_coalescedOnTime() {
        var c = InputStateMachine.Configuration()
        c.keyRepeatDelayUs = 2_000 * msec
        c.keyRepeatIntervalUs = 1_000 * msec
        var h = MailboxHost(configuration: c)
        h.note()
        h.deliver(keyDown(Scan.a))
        let downAt = h.d.now
        h.run(for: 6_500 * msec, noteEvery: 500 * msec)
        // Exactly the configured schedule: +2 s, then every 1 s. A false resume would push each one later.
        #expect(h.repeatTimes == [2_000, 3_000, 4_000, 5_000, 6_000].map { downAt + UInt64($0) * msec })
        #expect(h.wakes == 0)
        #expect(h.staleRepeats.isEmpty)
        #expect(!h.d.machine.isKeyRepeatPaused(at: h.d.now))
    }

    @Test("MBOX-1b the same with the macOS default timing: one repeat every 83 ms, none lost or delayed")
    func mbox1b_defaultTiming() {
        var h = MailboxHost(configuration: macDefaults())
        h.note()
        h.deliver(keyDown(Scan.a))
        let downAt = h.d.now
        h.run(for: 3_000 * msec, noteEvery: 500 * msec)
        let expected = stride(from: UInt64(500), through: 3_000, by: 83).map { downAt + $0 * msec }
        #expect(h.repeatTimes == expected)
        #expect(h.wakes == 0)
    }

    @Test("MBOX-2 a real receive gap still pauses, wakes the input queue once and resumes one interval later")
    func mbox2_realGap() {
        var h = MailboxHost(configuration: macDefaults())
        h.note()
        h.deliver(keyDown(Scan.a))
        h.run(for: 1_000 * msec, noteEvery: 500 * msec)
        let beforeStall = h.repeatTimes.count
        h.run(for: 1_400 * msec, noteEvery: nil)  // the stall: 1.4 s without any record
        let lastBeforeGap = h.lastNote!
        #expect(h.d.machine.isKeyRepeatPaused(at: h.d.now))
        #expect(h.repeatTimes.allSatisfy { $0 <= lastBeforeGap + 600 * msec })
        #expect(h.repeatTimes.count > beforeStall)  // it repeated until the pause began
        let paused = h.repeatTimes.count
        h.note()  // the first record after the stall
        let resumedAt = h.d.now
        #expect(h.wakes == 1)
        h.run(for: 500 * msec, noteEvery: 100 * msec)
        let after = Array(h.repeatTimes.dropFirst(paused))
        #expect(after.first == resumedAt + 83 * msec)
        #expect(after.count == 6)  // +83 ... +498
        #expect(h.staleRepeats.isEmpty)
    }

    @Test("MBOX-3 a delayed KEY UP after a stall: key-up with no repeat before it, through the mailbox")
    func mbox3_delayedUp() {
        var h = MailboxHost(configuration: macDefaults())
        h.note()
        h.deliver(keyDown(Scan.a))
        h.run(for: 1_500 * msec, noteEvery: nil)
        let repeatsBefore = h.repeatTimes.count
        h.d.now += 1 * msec
        let up = h.deliver(keyUp(Scan.a))
        #expect(withoutCaps(up) == [.keyUp(keyCode: 0x00)])
        #expect(h.repeatTimes.count == repeatsBefore)
        #expect(!h.d.machine.hasHeldInput)
        #expect(h.staleRepeats.isEmpty)
    }

    @Test("MBOX-4 wake-ups are bounded: one outstanding at most, cleared only by the wake-up's own hand-off")
    func mbox4_boundedWakes() {
        var m = ControlActivityMailbox(stallGapUs: 600 * msec)
        #expect(m.take() == nil)
        let first = m.note(0)
        #expect(!first)  // the first record after a reset is no gap
        var asked = 0
        for i in 1...50 where m.note(UInt64(i) * 1_000 * msec) { asked += 1 }  // 50 gaps, the input queue blocked
        #expect(asked == 1)
        #expect(m.wakePending)
        // A message's hand-off does not clear the outstanding wake-up (its closure is still queued).
        #expect(m.take() == ControlActivityHandoff(latest: 50_000 * msec, resumedAt: 50_000 * msec))
        let again = m.note(51_000 * msec)
        #expect(!again)
        #expect(m.takeForWake() == ControlActivityHandoff(latest: 51_000 * msec, resumedAt: 51_000 * msec))
        #expect(!m.wakePending)
        #expect(m.take() == ControlActivityHandoff(latest: 51_000 * msec, resumedAt: nil))  // the gap was handed off
        let next = m.note(52_000 * msec)
        #expect(next)  // a new gap may ask again
    }

    @Test("MBOX-5 the gap is between consecutive records, never lost before a hand-off; backwards clock and reset")
    func mbox5_gapBetweenRecords() {
        var m = ControlActivityMailbox(stallGapUs: 600 * msec)
        for i in 0...20 { _ = m.note(UInt64(i) * 500 * msec) }
        #expect(m.take() == ControlActivityHandoff(latest: 10_000 * msec, resumedAt: nil))
        // A gap followed by many on-time records before the hand-off is not lost.
        _ = m.note(11_000 * msec)
        for i in 1...10 { _ = m.note(11_000 * msec + UInt64(i) * 100 * msec) }
        #expect(m.take() == ControlActivityHandoff(latest: 12_000 * msec, resumedAt: 11_000 * msec))
        // A backwards clock is no gap; reset forgets everything.
        let backwards = m.note(1_000 * msec)
        #expect(!backwards)
        #expect(m.latest == 1_000 * msec)
        m.reset()
        #expect(m.take() == nil)
        #expect(m.resumedAt == nil)
    }

    @Test("MBOX-6 a hand-off with a gap but no armed repeat changes nothing and reports no resume")
    func mbox6_noRepeat() {
        var d = Driver(configuration: macDefaults())
        let resumed = d.machine.noteControlActivity(ControlActivityHandoff(latest: d.now, resumedAt: d.now))
        #expect(!resumed)
        #expect(d.machine.lastControlActivity == d.now)
        #expect(d.machine.nextDeadline(now: d.now) == nil)
    }

    @Test("MBOX-7 a record just under the pause, handled while the threshold passes, does not leave the timer disarmed")
    func mbox7_processingStraddlesThreshold() {
        var h = MailboxHost(configuration: macDefaults())
        h.note()  // activity at T0
        let t0 = h.d.now
        h.nextPoll = t0 + 500 * msec
        h.run(for: 599 * msec, noteEvery: nil)  // the poll at +500 hands off T0 and re-arms (nothing armed yet)
        // KEY DOWN received at +599 (599 ms gap: no stall), its handling ends at +604: the re-arm sees the activity
        // from before it (604 ms old), finds the new repeat paused and leaves it without a timer.
        h.deliver(keyDown(Scan.a), processing: 5 * msec)
        #expect(h.wakes == 1)  // the record's own note (599 ms gap) wakes the parked repeat
        #expect(h.timerAt == t0 + 1_099 * msec)
        h.run(for: 96 * msec, noteEvery: nil)
        h.note()  // PING at +700
        h.run(for: 450 * msec, noteEvery: nil)  // to +1150
        #expect(h.repeatTimes == [t0 + 1_099 * msec])  // on time, not at the +1500 poll
        #expect(h.staleRepeats.isEmpty)
    }

    @Test("MBOX-8 parked repeat: a waiting note wakes once; no wake without a note or while one is outstanding")
    func mbox8_parkedWakes() {
        var m = ControlActivityMailbox(stallGapUs: 600 * msec)
        _ = m.note(0)
        _ = m.take()
        let parkedNothingWaiting = m.setRepeatParked(true)
        #expect(!parkedNothingWaiting)
        let noteWhileParked = m.note(100 * msec)  // no gap, but the repeat has no timer
        #expect(noteWhileParked)
        let second = m.note(200 * msec)
        #expect(!second)  // one wake-up outstanding at most
        #expect(m.takeForWake() == ControlActivityHandoff(latest: 200 * msec, resumedAt: nil))
        let unparked = m.setRepeatParked(false)
        #expect(!unparked)
        let notParked = m.note(300 * msec)
        #expect(!notParked)
        // Parked while a note is waiting (a note landed between a hand-off and the re-arm): wake at once.
        let parkedWithWaiting = m.setRepeatParked(true)
        #expect(parkedWithWaiting)
        let blocked = m.setRepeatParked(true)
        #expect(!blocked)
        m.reset()
        #expect(!m.repeatParked && !m.hasUntaken)
    }
}
