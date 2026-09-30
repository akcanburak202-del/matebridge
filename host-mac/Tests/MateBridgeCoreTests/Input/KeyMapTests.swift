import Testing
@testable import MateBridgeCore

// KMAP-*: the key identity table (PROTOCOL.md section 4 KEY, decision 0008).

private let map = KeyMap()

@Suite("KMAP: key identity to macOS keycode")
struct KeyMapTests {
    @Test("KMAP-1 letters, digits and the ANSI punctuation keys land on the right kVK codes")
    func kmap1_basics() {
        #expect(map.resolve(identity: 30) == .key(0x00))  // A
        #expect(map.resolve(identity: 44) == .key(0x06))  // Z
        #expect(map.resolve(identity: 16) == .key(0x0C))  // Q
        #expect(map.resolve(identity: 2) == .key(0x12))  // 1
        #expect(map.resolve(identity: 11) == .key(0x1D))  // 0
        #expect(map.resolve(identity: 1) == .key(0x35))  // Esc
        #expect(map.resolve(identity: 14) == .key(0x33))  // Backspace is kVK_Delete
        #expect(map.resolve(identity: 28) == .key(0x24))  // Enter is kVK_Return
        #expect(map.resolve(identity: 57) == .key(0x31))  // Space
        #expect(map.resolve(identity: 15) == .key(0x30))  // Tab
        #expect(map.resolve(identity: 111) == .key(0x75))  // Delete is kVK_ForwardDelete
    }

    @Test("KMAP-2 the twelve punctuation keys of the Turkish PC layout are all mapped (evdev 12 13 26 27 39 40 41 43 51 52 53 86)")
    func kmap2_punctuation() {
        for scan: UInt32 in [12, 13, 26, 27, 39, 40, 41, 43, 51, 52, 53, 86] {
            #expect(map.resolve(identity: scan) != nil, "evdev \(scan)")
        }
        #expect(map.resolve(identity: 12) == .key(0x1B))
        #expect(map.resolve(identity: 13) == .key(0x18))
        #expect(map.resolve(identity: 26) == .key(0x21))
        #expect(map.resolve(identity: 27) == .key(0x1E))
        #expect(map.resolve(identity: 39) == .key(0x29))
        #expect(map.resolve(identity: 40) == .key(0x27))
        #expect(map.resolve(identity: 43) == .key(0x2A))
        #expect(map.resolve(identity: 51) == .key(0x2B))
        #expect(map.resolve(identity: 52) == .key(0x2F))
        #expect(map.resolve(identity: 53) == .key(0x2C))
    }

    @Test("KMAP-3 ISO swap (decision 0008): top-left key is kVK_ISO_Section, the key next to left Shift is kVK_ANSI_Grave")
    func kmap3_isoSwap() {
        #expect(map.resolve(identity: 41) == .key(0x0A))
        #expect(map.resolve(identity: 86) == .key(0x32))
    }

    @Test("KMAP-4 arrows, navigation, F1 to F12 and keypad; Insert is Help")
    func kmap4_navigation() {
        #expect(map.resolve(identity: 105) == .key(0x7B))  // Left
        #expect(map.resolve(identity: 106) == .key(0x7C))
        #expect(map.resolve(identity: 108) == .key(0x7D))
        #expect(map.resolve(identity: 103) == .key(0x7E))
        #expect(map.resolve(identity: 102) == .key(0x73))  // Home
        #expect(map.resolve(identity: 107) == .key(0x77))  // End
        #expect(map.resolve(identity: 104) == .key(0x74))  // Page Up
        #expect(map.resolve(identity: 109) == .key(0x79))  // Page Down
        #expect(map.resolve(identity: 110) == .key(0x72))  // Insert -> Help
        let f: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        let scans: [UInt32] = [59, 60, 61, 62, 63, 64, 65, 66, 67, 68, 87, 88]
        for (scan, code) in zip(scans, f) { #expect(map.resolve(identity: scan) == .key(code), "F key evdev \(scan)") }
        #expect(map.resolve(identity: 82) == .key(0x52))  // keypad 0
        #expect(map.resolve(identity: 96) == .key(0x4C))  // keypad Enter
    }

    @Test("KMAP-5 default modifier mapping (decision 0008): Ctrl is Command, Alt is Option, Meta is Control, Shift is Shift")
    func kmap5_modifiers() {
        #expect(map.resolve(identity: 29) == .modifier(.leftCommand))
        #expect(map.resolve(identity: 97) == .modifier(.rightCommand))
        #expect(map.resolve(identity: 56) == .modifier(.leftOption))
        #expect(map.resolve(identity: 100) == .modifier(.rightOption))
        #expect(map.resolve(identity: 125) == .modifier(.leftControl))
        #expect(map.resolve(identity: 126) == .modifier(.rightControl))
        #expect(map.resolve(identity: 42) == .modifier(.leftShift))
        #expect(map.resolve(identity: 54) == .modifier(.rightShift))
    }

    @Test("KMAP-6 the modifier mapping is a setting: a swapped table changes only the modifiers")
    func kmap6_settable() {
        var swapped = ModifierMapping.default
        swapped.table[.leftControl] = .leftControl
        swapped.table[.leftMeta] = .leftCommand
        let m = KeyMap(modifiers: swapped)
        #expect(m.resolve(identity: 29) == .modifier(.leftControl))
        #expect(m.resolve(identity: 125) == .modifier(.leftCommand))
        #expect(m.resolve(identity: 30) == .key(0x00))
    }

    @Test("KMAP-7 Caps Lock (evdev 58, KEYCODE_CAPS_LOCK) is its own target")
    func kmap7_caps() {
        #expect(map.resolve(identity: 58) == .capsLock)
        #expect(map.resolve(identity: 0x10000 + 115) == .capsLock)
    }

    @Test("KMAP-8 keys without a scan code come through android_key_code")
    func kmap8_androidFallback() {
        #expect(map.resolve(identity: 0x10000 + 29) == .key(0x00))  // KEYCODE_A
        #expect(map.resolve(identity: 0x10000 + 54) == .key(0x06))  // KEYCODE_Z
        #expect(map.resolve(identity: 0x10000 + 7) == .key(0x1D))  // KEYCODE_0
        #expect(map.resolve(identity: 0x10000 + 16) == .key(0x19))  // KEYCODE_9
        #expect(map.resolve(identity: 0x10000 + 66) == .key(0x24))  // KEYCODE_ENTER
        #expect(map.resolve(identity: 0x10000 + 67) == .key(0x33))  // KEYCODE_DEL is backspace
        #expect(map.resolve(identity: 0x10000 + 112) == .key(0x75))  // KEYCODE_FORWARD_DEL
        #expect(map.resolve(identity: 0x10000 + 131) == .key(0x7A))  // F1
        #expect(map.resolve(identity: 0x10000 + 142) == .key(0x6F))  // F12
        #expect(map.resolve(identity: 0x10000 + 113) == .modifier(.leftCommand))  // CTRL_LEFT
        #expect(map.resolve(identity: 0x10000 + 57) == .modifier(.leftOption))  // ALT_LEFT
        #expect(map.resolve(identity: 0x10000 + 59) == .modifier(.leftShift))
    }

    @Test("KMAP-9 unknown identities are nil, never a guess")
    func kmap9_unknown() {
        #expect(map.resolve(identity: 0) == nil)
        #expect(map.resolve(identity: 84) == nil)
        #expect(map.resolve(identity: 69) == nil)  // Num Lock has no Mac key
        #expect(map.resolve(identity: 0x10000 + 85) == nil)  // KEYCODE_MEDIA_PLAY_PAUSE (out of scope)
        #expect(map.resolve(identity: 0x10000) == nil)
        #expect(map.resolve(identity: 0x20000) == nil)
        #expect(map.resolve(identity: UInt32.max) == nil)
    }

    @Test("KMAP-10 two physical keys never share a Mac keycode, and no table entry collides with a modifier or Caps Lock")
    func kmap10_tableConsistency() {
        let codes = Array(KeyMap.evdevToMac.values)
        #expect(Set(codes).count == codes.count)
        let modifierCodes = Set(ModifierKey.allCases.map(\.keyCode))
        #expect(modifierCodes.isDisjoint(with: Set(codes)))
        #expect(!codes.contains(0x39))  // kVK_CapsLock is never injected
        #expect(KeyMap.evdevToMac[58] == nil && KeyMap.evdevToMac[29] == nil)
        for (_, evdev) in KeyMap.androidToEvdev {
            #expect(evdev == KeyMap.evdevCapsLock || KeyMap.pcModifiers[evdev] != nil || KeyMap.evdevToMac[evdev] != nil,
                    "android fallback points at evdev \(evdev), which is unmapped")
        }
    }

    @Test("KMAP-11 flags: aggregate masks are CGEventFlags values and a side bit tells left from right")
    func kmap11_flags() {
        #expect(KeyFlags.command.rawValue == 0x100000)
        #expect(KeyFlags.shift.rawValue == 0x20000)
        #expect(KeyFlags.option.rawValue == 0x80000)
        #expect(KeyFlags.control.rawValue == 0x40000)
        #expect(KeyFlags.capsLock.rawValue == 0x10000)
        let both = KeyFlags(holding: [ModifierKey.leftCommand, .rightCommand])
        #expect(both.contains(.command) && both.rawValue == 0x100000 | 0x08 | 0x10)
        let one = KeyFlags(holding: [ModifierKey.rightCommand])
        #expect(one.rawValue == 0x100000 | 0x10)
        #expect(KeyFlags(holding: [ModifierKey]()).isEmpty)
    }
}
