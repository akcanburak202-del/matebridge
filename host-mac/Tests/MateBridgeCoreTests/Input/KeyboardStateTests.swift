import Foundation
import Testing
@testable import MateBridgeCore

// KEY-*: the keyboard half of the state machine (PROTOCOL.md section 4 KEY, section 7; decisions 0003 and 0008).

func keyMsg(_ scan: UInt16, _ action: KeyAction, caps: Bool = false, android: UInt16 = 0) -> Message {
    .key(KeyEvent(timeUs: 0, scanCode: scan, androidKeyCode: android, action: action, capsLockOn: caps))
}

func keyDown(_ scan: UInt16, caps: Bool = false) -> Message { keyMsg(scan, .down, caps: caps) }
func keyUp(_ scan: UInt16, caps: Bool = false) -> Message { keyMsg(scan, .up, caps: caps) }

/// PC evdev codes used in the tests.
enum Scan {
    static let a: UInt16 = 30
    static let b: UInt16 = 48
    static let c: UInt16 = 46
    static let tab: UInt16 = 15
    static let lctrl: UInt16 = 29
    static let rctrl: UInt16 = 97
    static let lshift: UInt16 = 42
    static let lalt: UInt16 = 56
    static let ralt: UInt16 = 100
    static let lmeta: UInt16 = 125
    static let caps: UInt16 = 58
}

/// The actions without the Caps Lock state that accompanies every key message.
func withoutCaps(_ actions: [InjectAction]) -> [InjectAction] {
    actions.filter { if case .setCapsLock = $0 { false } else { true } }
}

@Suite("KEY: keyboard state machine")
struct KeyboardStateTests {
    @Test("KEY-1 a key goes down and up once, with the mapped keycode")
    func key1_downUp() {
        var d = Driver()
        #expect(d.send(keyDown(Scan.a)) == [.setCapsLock(false), .keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(d.machine.hasHeldInput)
        #expect(d.send(keyUp(Scan.a)) == [.setCapsLock(false), .keyUp(keyCode: 0x00)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("KEY-2 a second DOWN of a held key and an UP of a key that is not held do nothing")
    func key2_duplicates() {
        var d = Driver()
        d.send(keyDown(Scan.a))
        #expect(withoutCaps(d.send(keyDown(Scan.a))) == [])
        #expect(withoutCaps(d.send(keyUp(Scan.b))) == [])
        #expect(withoutCaps(d.send(keyUp(Scan.a))) == [.keyUp(keyCode: 0x00)])
        #expect(withoutCaps(d.send(keyUp(Scan.a))) == [])
    }

    @Test("KEY-3 modifiers are modifier events and the letters in between are ordinary keys (Ctrl+C is Cmd+C)")
    func key3_modifiers() {
        var d = Driver()
        #expect(withoutCaps(d.send(keyDown(Scan.lctrl))) == [.modifierDown(.leftCommand)])
        #expect(withoutCaps(d.send(keyDown(Scan.c))) == [.keyDown(keyCode: 0x08, autorepeat: false)])
        #expect(withoutCaps(d.send(keyUp(Scan.c))) == [.keyUp(keyCode: 0x08)])
        #expect(withoutCaps(d.send(keyUp(Scan.lctrl))) == [.modifierUp(.leftCommand)])
    }

    @Test("KEY-4 AltGr is the right Option and Meta is Control (decision 0008)")
    func key4_defaultMapping() {
        var d = Driver()
        #expect(withoutCaps(d.send(keyDown(Scan.ralt))) == [.modifierDown(.rightOption)])
        #expect(withoutCaps(d.send(keyDown(Scan.lmeta))) == [.modifierDown(.leftControl)])
    }

    @Test("KEY-5 an UP releases what the DOWN injected; two identities for one Mac key: one down, one up")
    func key5_sharedKey() {
        var d = Driver()
        let android: Message = keyMsg(0, .down, android: 29)  // KEYCODE_A without a scan code
        #expect(withoutCaps(d.send(keyDown(Scan.a))) == [.keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(withoutCaps(d.send(android)) == [])  // the Mac already holds A
        #expect(withoutCaps(d.send(keyUp(Scan.a))) == [])  // the other identity still holds it
        #expect(d.machine.hasHeldInput)
        #expect(withoutCaps(d.send(keyMsg(0, .up, android: 29))) == [.keyUp(keyCode: 0x00)])
        #expect(!d.machine.hasHeldInput)
    }

    @Test("KEY-6 a key with only an android key code works; both codes zero is nothing")
    func key6_identity() {
        var d = Driver()
        #expect(withoutCaps(d.send(keyMsg(0, .down, android: 66))) == [.keyDown(keyCode: 0x24, autorepeat: false)])
        #expect(d.send(keyMsg(0, .down)) == [])
        #expect(d.machine.keyCounters.unknown == 1)
    }

    @Test("KEY-7 an unknown key injects nothing, is counted, and its identity is kept for a debug line")
    func key7_unknown() {
        var d = Driver()
        #expect(withoutCaps(d.send(keyDown(84))) == [])
        #expect(withoutCaps(d.send(keyUp(84))) == [])
        #expect(d.machine.keyCounters.unknown == 2)
        #expect(d.machine.keyCounters.lastUnknownIdentity == 84)
        #expect(d.machine.keyCounters.messages == 2)
        #expect(!d.machine.hasHeldInput)
    }

    // MARK: Caps Lock

    @Test("KEY-8 the Caps key is never injected; its UP carries the state to apply, its DOWN nothing")
    func key8_capsKey() {
        var d = Driver()
        #expect(d.send(keyDown(Scan.caps, caps: false)) == [])
        #expect(d.send(keyUp(Scan.caps, caps: true)) == [.setCapsLock(true)])
        #expect(d.send(keyDown(Scan.caps, caps: true)) == [])
        #expect(d.send(keyUp(Scan.caps, caps: false)) == [.setCapsLock(false)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.send(keyMsg(0, .up, caps: true, android: 115)) == [.setCapsLock(true)])  // KEYCODE_CAPS_LOCK alone
    }

    @Test("KEY-9 every other key event carries the state first, so the key already sees it")
    func key9_capsOnOtherKeys() {
        var d = Driver()
        #expect(d.send(keyDown(Scan.a, caps: true)) == [.setCapsLock(true), .keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(d.send(keyUp(Scan.a, caps: true)) == [.setCapsLock(true), .keyUp(keyCode: 0x00)])
        #expect(d.send(keyDown(84, caps: true)) == [.setCapsLock(true)])  // even an unknown one
    }

    // MARK: Auto-repeat

    @Test("KEY-10 the last pressed ordinary key repeats after the delay, then at the interval")
    func key10_repeat() {
        var c = InputStateMachine.Configuration()
        c.keyRepeatDelayUs = 400 * msec
        c.keyRepeatIntervalUs = 50 * msec
        var d = Driver(configuration: c)
        d.send(keyDown(Scan.a))
        let downAt = d.now
        #expect(d.machine.nextDeadline(now: d.now) == downAt + 400 * msec)
        #expect(d.tick(after: 399 * msec) == [])
        #expect(d.tick(after: 1 * msec) == [.keyDown(keyCode: 0x00, autorepeat: true)])
        #expect(d.machine.nextDeadline(now: d.now) == downAt + 450 * msec)
        #expect(d.tick(after: 49 * msec) == [])
        #expect(d.tick(after: 1 * msec) == [.keyDown(keyCode: 0x00, autorepeat: true)])
        #expect(d.machine.keyCounters.repeats == 2)
    }

    @Test("KEY-11 the repeat stops at the key's UP, at another key's DOWN, and never starts for a modifier")
    func key11_repeatStops() {
        var d = Driver()
        d.send(keyDown(Scan.a))
        d.send(keyUp(Scan.a))
        #expect(d.machine.nextDeadline(now: d.now) == nil)
        #expect(d.tick(after: 5_000 * msec) == [])

        d.send(keyDown(Scan.a))
        d.send(keyDown(Scan.b))  // b repeats now, not a
        #expect(d.tick(after: 600 * msec) == [.keyDown(keyCode: 0x0B, autorepeat: true)])
        d.send(keyDown(Scan.lctrl))  // any other DOWN stops it
        #expect(d.tick(after: 5_000 * msec) == [])
        d.send(keyUp(Scan.lctrl))
        d.send(keyDown(Scan.lshift))
        #expect(d.machine.nextDeadline(now: d.now) == nil)
    }

    @Test("KEY-12 an ignored duplicate DOWN does not restart the repeat; the UP of another key does not stop it")
    func key12_repeatSurvives() {
        var c = InputStateMachine.Configuration()
        c.keyRepeatDelayUs = 500 * msec
        var d = Driver(configuration: c)
        d.send(keyDown(Scan.a))
        let first = d.machine.nextDeadline(now: d.now)
        d.send(keyDown(Scan.a), after: 100 * msec)
        #expect(d.machine.nextDeadline(now: d.now) == first)
        d.send(keyUp(Scan.b), after: 10 * msec)
        #expect(d.machine.nextDeadline(now: d.now) == first)
    }

    @Test("KEY-13 a late timer produces one repeat, not a burst; a message also runs an overdue repeat first")
    func key13_lateTimer() {
        var d = Driver()
        d.send(keyDown(Scan.a))
        let late = d.tick(after: 10_000 * msec)
        #expect(late == [.keyDown(keyCode: 0x00, autorepeat: true)])
        #expect(d.tick(after: 1 * msec) == [])
        // Through `handle`: the overdue repeat comes before the message's own actions.
        d.jump(1_000 * Int64(msec))
        let actions = d.send(keyDown(Scan.b), after: 0)
        #expect(withoutCaps(actions) == [.keyDown(keyCode: 0x00, autorepeat: true), .keyDown(keyCode: 0x0B, autorepeat: false)])
    }

    @Test("KEY-14 a clock that goes backwards does not stall the repeat for long")
    func key14_backwardsClock() {
        var d = Driver()
        d.send(keyDown(Scan.a))
        d.jump(-5_000 * Int64(msec))
        let due = d.machine.nextDeadline(now: d.now)
        #expect(due != nil && due! <= d.now + 500 * msec)
        d.now = due!
        #expect(d.machine.tick(now: d.now) == [.keyDown(keyCode: 0x00, autorepeat: true)])
    }

    // MARK: Release-all

    @Test("KEY-15 release-all releases keys (last pressed first), then modifiers, and stops the repeat")
    func key15_releaseAll() {
        var d = Driver()
        d.send(keyDown(Scan.lctrl))
        d.send(keyDown(Scan.lshift))
        d.send(keyDown(Scan.a))
        d.send(keyDown(Scan.b))
        #expect(d.release() == [
            .keyUp(keyCode: 0x0B), .keyUp(keyCode: 0x00), .modifierUp(.leftShift), .modifierUp(.leftCommand),
        ])
        #expect(!d.machine.hasHeldInput)
        #expect(d.machine.nextDeadline(now: d.now) == nil)
        #expect(d.release() == [])  // idempotent
    }

    @Test("KEY-16 release-all through the message, BYE and every cause releases the keyboard", arguments: allReleaseCauses)
    func key16_everyCause(_ cause: ReleaseCause) {
        var d = Driver()
        d.send(keyDown(Scan.rctrl))
        d.send(keyDown(Scan.tab))
        let actions = d.release(cause)
        #expect(actions == [.keyUp(keyCode: 0x30), .modifierUp(.rightCommand)])
        #expect(!d.machine.hasHeldInput)
        #expect(d.tick(after: 5_000 * msec) == [])
    }

    @Test("KEY-17 an UP arriving after a release-all is not a stray release")
    func key17_upAfterRelease() {
        var d = Driver()
        d.send(keyDown(Scan.a))
        d.release()
        #expect(withoutCaps(d.send(keyUp(Scan.a))) == [])
        #expect(withoutCaps(d.send(keyDown(Scan.a))) == [.keyDown(keyCode: 0x00, autorepeat: false)])
    }

    @Test("KEY-18 the release keeps pen and pointer rules: a held button and a key release together")
    func key18_mixedRelease() {
        var d = Driver()
        d.send(absMsg(.mouse, 500, 600, .left))
        d.send(keyDown(Scan.lctrl))
        let actions = d.release()
        #expect(actions == [.mouseButton(.left, down: false), .modifierUp(.leftCommand)])
    }

    // MARK: Fixtures

    @Test("KEY-19 the key_* fixtures decode and drive the machine")
    func key19_fixtures() throws {
        func message(_ name: String) throws -> Message {
            var decoder = FrameDecoder(connection: .control)
            decoder.append(Fixtures.bytes(name))
            return try #require(try decoder.nextMessage())
        }
        var d = Driver()
        #expect(d.send(try message("key_down")) == [.setCapsLock(false), .keyDown(keyCode: 0x00, autorepeat: false)])
        #expect(d.send(try message("key_up_caps")) == [.setCapsLock(true)])  // Caps UP, lock state on
        // key_no_scan: KEYCODE_MEDIA_PLAY_PAUSE (85), unmapped: nothing injected.
        #expect(withoutCaps(d.send(try message("key_no_scan"))) == [])
        #expect(d.machine.keyCounters.unknown == 1)
    }
}
