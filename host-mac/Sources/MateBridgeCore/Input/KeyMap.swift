// Key identity to macOS virtual keycode (docs/PROTOCOL.md section 4 KEY, decisions 0003 and 0008).
//
// The tablet sends the physical key: a Linux evdev `scan_code`, or for keys without one `0x10000 + android_key_code`
// (`KeyEvent.keyIdentity`). This file is the one table that turns that into what the Mac is told. Pure data, no
// system calls. The modifier part is a separate setting (`ModifierMapping`), because decision 0008 makes it a default
// the user may change in phase 4, while the rest of the table is fixed physical geometry.

/// One of the eight Mac modifier keys. The raw value is the macOS virtual keycode (`kVK_*`).
public enum ModifierKey: UInt16, CaseIterable, Hashable, Sendable {
    case leftCommand = 0x37
    case rightCommand = 0x36
    case leftShift = 0x38
    case rightShift = 0x3C
    case leftOption = 0x3A
    case rightOption = 0x3D
    case leftControl = 0x3B
    case rightControl = 0x3E

    public var keyCode: UInt16 { rawValue }

    /// The aggregate flag (`CGEventFlags.maskCommand` and friends): set while either side is held.
    var aggregate: KeyFlags {
        switch self {
        case .leftCommand, .rightCommand: .command
        case .leftShift, .rightShift: .shift
        case .leftOption, .rightOption: .option
        case .leftControl, .rightControl: .control
        }
    }

    /// The device-dependent side bit (`NX_DEVICELCMDKEYMASK` and friends), which tells left from right.
    var side: KeyFlags {
        switch self {
        case .leftControl: KeyFlags(rawValue: 0x0000_0001)
        case .leftShift: KeyFlags(rawValue: 0x0000_0002)
        case .rightShift: KeyFlags(rawValue: 0x0000_0004)
        case .leftCommand: KeyFlags(rawValue: 0x0000_0008)
        case .rightCommand: KeyFlags(rawValue: 0x0000_0010)
        case .leftOption: KeyFlags(rawValue: 0x0000_0020)
        case .rightOption: KeyFlags(rawValue: 0x0000_0040)
        case .rightControl: KeyFlags(rawValue: 0x0000_2000)
        }
    }
}

/// Modifier state as CGEvent flags. The raw bits are exactly `CGEventFlags`' (aggregate masks in the high half,
/// device-dependent left/right bits in the low half), so the host can build a `CGEventFlags` from `rawValue`.
public struct KeyFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let capsLock = KeyFlags(rawValue: 0x0001_0000)
    public static let shift = KeyFlags(rawValue: 0x0002_0000)
    public static let control = KeyFlags(rawValue: 0x0004_0000)
    public static let option = KeyFlags(rawValue: 0x0008_0000)
    public static let command = KeyFlags(rawValue: 0x0010_0000)

    /// The flags of a set of held modifiers. Either side held keeps the aggregate flag; each side keeps its own bit,
    /// so releasing one of two held sides leaves the aggregate and the other side's bit in place.
    public init<S: Sequence>(holding modifiers: S) where S.Element == ModifierKey {
        self = modifiers.reduce(into: KeyFlags()) { $0.formUnion($1.aggregate); $0.formUnion($1.side) }
    }
}

/// What a key identity turns into on the Mac.
public enum KeyTarget: Equatable, Sendable {
    /// An ordinary key (`keyDown` / `keyUp` with this virtual keycode).
    case key(UInt16)
    /// A modifier (`flagsChanged`).
    case modifier(ModifierKey)
    /// Caps Lock: never injected as a key; its state is set instead (PROTOCOL.md section 4).
    case capsLock
}

/// The PC modifier keys, before the Mac mapping is applied.
public enum PCModifier: CaseIterable, Hashable, Sendable {
    case leftShift, rightShift, leftControl, rightControl, leftAlt, rightAlt, leftMeta, rightMeta
}

/// Decision 0008: which Mac modifier each PC modifier becomes. One value, one place; phase 4 settings replace it.
public struct ModifierMapping: Equatable, Sendable {
    public var table: [PCModifier: ModifierKey]

    public init(table: [PCModifier: ModifierKey]) { self.table = table }

    /// Ctrl acts as Command (Mac shortcuts on the PC finger habit), Alt as Option (AltGr characters of the Turkish PC
    /// layout come from the right Option), Meta as Control.
    public static let `default` = ModifierMapping(table: [
        .leftShift: .leftShift, .rightShift: .rightShift,
        .leftControl: .leftCommand, .rightControl: .rightCommand,
        .leftAlt: .leftOption, .rightAlt: .rightOption,
        .leftMeta: .leftControl, .rightMeta: .rightControl,
    ])

    func resolve(_ pc: PCModifier) -> ModifierKey { table[pc] ?? Self.default.table[pc]! }
}

public struct KeyMap: Equatable, Sendable {
    public var modifiers: ModifierMapping

    public init(modifiers: ModifierMapping = .default) { self.modifiers = modifiers }

    /// nil: unknown key, nothing is injected.
    public func resolve(identity: UInt32) -> KeyTarget? {
        let scan: UInt16
        if identity >= 0x10000 {
            guard identity <= 0x1FFFF, let evdev = Self.androidToEvdev[UInt16(identity - 0x10000)] else { return nil }
            scan = evdev
        } else {
            scan = UInt16(identity)
        }
        if scan == Self.evdevCapsLock { return .capsLock }
        if let pc = Self.pcModifiers[scan] { return .modifier(modifiers.resolve(pc)) }
        return Self.evdevToMac[scan].map { .key($0) }
    }

    // MARK: Tables

    static let evdevCapsLock: UInt16 = 58

    static let pcModifiers: [UInt16: PCModifier] = [
        42: .leftShift, 54: .rightShift, 29: .leftControl, 97: .rightControl, 56: .leftAlt, 100: .rightAlt,
        125: .leftMeta, 126: .rightMeta,
    ]

    /// evdev scan code to macOS virtual keycode (`kVK_*`), physical position on an ISO PC keyboard mapped to the same
    /// physical position on an ISO Mac keyboard. Evdev 41 (left of `1`) and 86 (right of left Shift) swap the two
    /// codes the ANSI names suggest (decision 0008): on ISO Mac keyboards the top-left key is `kVK_ISO_Section` (0x0A)
    /// and the one next to Shift is `kVK_ANSI_Grave` (0x32).
    static let evdevToMac: [UInt16: UInt16] = [
        1: 0x35,    // Esc
        2: 0x12, 3: 0x13, 4: 0x14, 5: 0x15, 6: 0x17, 7: 0x16, 8: 0x1A, 9: 0x1C, 10: 0x19, 11: 0x1D,  // 1 ... 0
        12: 0x1B,   // minus
        13: 0x18,   // equal
        14: 0x33,   // Backspace (kVK_Delete)
        15: 0x30,   // Tab
        16: 0x0C, 17: 0x0D, 18: 0x0E, 19: 0x0F, 20: 0x11, 21: 0x10, 22: 0x20, 23: 0x22, 24: 0x1F, 25: 0x23,  // Q ... P
        26: 0x21,   // [
        27: 0x1E,   // ]
        28: 0x24,   // Enter (kVK_Return)
        30: 0x00, 31: 0x01, 32: 0x02, 33: 0x03, 34: 0x05, 35: 0x04, 36: 0x26, 37: 0x28, 38: 0x25,  // A ... L
        39: 0x29,   // ;
        40: 0x27,   // '
        41: 0x0A,   // ISO: top-left key (kVK_ISO_Section)
        43: 0x2A,   // backslash
        44: 0x06, 45: 0x07, 46: 0x08, 47: 0x09, 48: 0x0B, 49: 0x2D, 50: 0x2E,  // Z ... M
        51: 0x2B,   // comma
        52: 0x2F,   // period
        53: 0x2C,   // slash
        55: 0x43,   // keypad *
        57: 0x31,   // Space
        59: 0x7A, 60: 0x78, 61: 0x63, 62: 0x76, 63: 0x60, 64: 0x61, 65: 0x62, 66: 0x64, 67: 0x65, 68: 0x6D,  // F1 ... F10
        71: 0x59, 72: 0x5B, 73: 0x5C,   // keypad 7 8 9
        74: 0x4E,   // keypad -
        75: 0x56, 76: 0x57, 77: 0x58,   // keypad 4 5 6
        78: 0x45,   // keypad +
        79: 0x53, 80: 0x54, 81: 0x55,   // keypad 1 2 3
        82: 0x52,   // keypad 0
        83: 0x41,   // keypad .
        86: 0x32,   // ISO: key right of left Shift (kVK_ANSI_Grave)
        87: 0x67, 88: 0x6F,   // F11, F12
        96: 0x4C,   // keypad Enter
        98: 0x4B,   // keypad /
        102: 0x73,  // Home
        103: 0x7E,  // Up
        104: 0x74,  // Page Up
        105: 0x7B,  // Left
        106: 0x7C,  // Right
        107: 0x77,  // End
        108: 0x7D,  // Down
        109: 0x79,  // Page Down
        110: 0x72,  // Insert: the Mac has none, its position holds Help (kVK_Help)
        111: 0x75,  // Delete (kVK_ForwardDelete)
    ]

    /// Android `KEYCODE_*` to evdev scan code, for keys that arrive without a scan code. Only keys with a meaning on
    /// the Mac are listed; the rest stay unknown.
    static let androidToEvdev: [UInt16: UInt16] = {
        var t: [UInt16: UInt16] = [:]
        let letters: [UInt16] = [30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, 49, 24, 25, 16, 19, 31, 20, 22, 47,
                                 17, 45, 21, 44]  // A ... Z by alphabet
        for (i, scan) in letters.enumerated() { t[UInt16(29 + i)] = scan }
        let digits: [UInt16] = [11, 2, 3, 4, 5, 6, 7, 8, 9, 10]  // KEYCODE_0 ... KEYCODE_9
        for (i, scan) in digits.enumerated() { t[UInt16(7 + i)] = scan }
        for i in 0..<12 { t[UInt16(131 + i)] = i < 10 ? UInt16(59 + i) : UInt16(87 + i - 10) }  // F1 ... F12
        for (i, scan) in ([82, 79, 80, 81, 75, 76, 77, 71, 72, 73] as [UInt16]).enumerated() { t[UInt16(144 + i)] = scan }  // keypad 0 ... 9
        let others: [UInt16: UInt16] = [
            19: 103, 20: 108, 21: 105, 22: 106,  // D-pad up, down, left, right
            55: 51, 56: 52,  // comma, period
            57: 56, 58: 100,  // Alt left, right
            59: 42, 60: 54,  // Shift left, right
            61: 15, 62: 57, 66: 28, 67: 14, 68: 41, 69: 12, 70: 13, 71: 26, 72: 27, 73: 43, 74: 39, 75: 40, 76: 53,
            92: 104, 93: 109,  // Page up, down
            111: 1, 112: 111,  // Escape, forward delete
            113: 29, 114: 97,  // Ctrl left, right
            115: 58,  // Caps Lock
            117: 125, 118: 126,  // Meta left, right
            122: 102, 123: 107,  // Home, End
            124: 110,  // Insert
            154: 98, 155: 55, 156: 74, 157: 78, 158: 83, 160: 96,  // keypad / * - + . Enter
        ]
        t.merge(others) { a, _ in a }
        return t
    }()
}
