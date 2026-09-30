// Keyboard half of `InputStateMachine` (docs/PROTOCOL.md section 4 KEY, decisions 0003 and 0008). KEY-* rules:
//   KEY-UP-RECORD  an UP releases what the DOWN injected, never what the current mapping says
//   KEY-DUP        a second DOWN of a held key, and an UP of a key not held, do nothing
//   KEY-SHARED     two identities that map to the same Mac key: one down (the first), one up (the last)
//   KEY-CAPS       Caps Lock is never injected; every KEY event but the Caps DOWN carries the state to apply
//   KEY-REPEAT     the last pressed non-modifier key repeats; any other DOWN, its own UP and release-all stop it
//   KEY-RELEASE    release-all: key ups (last pressed first), then modifier ups

/// What was injected for a held key.
enum InjectedKey: Equatable, Sendable {
    case key(UInt16)
    case modifier(ModifierKey)
}

struct HeldKey: Equatable, Sendable {
    var identity: UInt32
    var injected: InjectedKey
}

struct KeyRepeat: Equatable, Sendable {
    var identity: UInt32
    var keyCode: UInt16
    var nextAt: UInt64
}

/// Keyboard counters (`key_msgs`, `unknown_keys`, `repeats` of the statistics line).
public struct KeyCounters: Equatable, Sendable {
    public var messages = 0
    /// Identities with no mapping (or no identity at all).
    public var unknown = 0
    /// Auto-repeat events generated.
    public var repeats = 0
    /// The identity of the most recent unknown key, for a debug log line (an identity is a number, never a character).
    public var lastUnknownIdentity: UInt32?
    public init() {}
}

extension InputStateMachine {
    mutating func handleKey(_ k: KeyEvent, now: UInt64) -> [InjectAction] {
        keyCounters.messages += 1
        guard let identity = k.keyIdentity else {
            keyCounters.unknown += 1
            keyCounters.lastUnknownIdentity = nil
            return []
        }
        let target = configuration.keyMap.resolve(identity: identity)

        // KEY-REPEAT: a DOWN of any other key identity stops the repeat, the Caps key and unmapped keys included (they
        // are not injected, but the user's hand has moved on). A duplicate DOWN of the repeating key itself does not.
        if k.action == .down, keyRepeat?.identity != identity { keyRepeat = nil }

        // KEY-CAPS: the Caps key itself is not injected; its UP carries the state. Every other event carries the state
        // too, and it is applied before the event so the event already sees it.
        if target == .capsLock {
            return k.action == .up ? [.setCapsLock(k.capsLockOn)] : []
        }
        var out: [InjectAction] = [.setCapsLock(k.capsLockOn)]

        guard let target else {
            keyCounters.unknown += 1
            keyCounters.lastUnknownIdentity = identity
            return out
        }
        let injected: InjectedKey
        switch target {
        case .key(let code): injected = .key(code)
        case .modifier(let m): injected = .modifier(m)
        case .capsLock: return out
        }

        switch k.action {
        case .down:
            guard !heldKeys.contains(where: { $0.identity == identity }) else { return out }  // KEY-DUP
            let shared = heldKeys.contains { $0.injected == injected }
            heldKeys.append(HeldKey(identity: identity, injected: injected))
            keyRepeat = nil  // KEY-REPEAT: any other DOWN stops the repeat
            if !shared {
                switch injected {
                case .key(let code): out.append(.keyDown(keyCode: code, autorepeat: false))
                case .modifier(let m): out.append(.modifierDown(m))
                }
            }
            if case .key(let code) = injected, configuration.keyRepeatEnabled {
                keyRepeat = KeyRepeat(identity: identity, keyCode: code, nextAt: now &+ configuration.keyRepeatDelayUs)
            }
        case .up:
            guard let index = heldKeys.firstIndex(where: { $0.identity == identity }) else { return out }  // KEY-DUP
            let record = heldKeys.remove(at: index)
            if keyRepeat?.identity == identity { keyRepeat = nil }
            if !heldKeys.contains(where: { $0.injected == record.injected }) {
                out.append(Self.release(record.injected))
            }
        }
        return out
    }

    /// KEY-REPEAT: one repeat of the repeating key if it is due. At most one per call; when the timer ran late the
    /// next one is a whole interval after `now`, so a stall never produces a burst.
    mutating func repeatKeyIfDue(now: UInt64) -> [InjectAction] {
        guard let r = keyRepeat, now >= r.nextAt else { return [] }
        let interval = Swift.max(configuration.keyRepeatIntervalUs, 1)
        let next = r.nextAt &+ interval
        keyRepeat?.nextAt = next > now ? next : now &+ interval
        keyCounters.repeats += 1
        return [.keyDown(keyCode: r.keyCode, autorepeat: true)]
    }

    /// KEY-RELEASE: everything held, last pressed first, ordinary keys before modifiers. Stops the repeat.
    mutating func releaseKeys() -> [InjectAction] {
        keyRepeat = nil
        let held = heldKeys.reversed()
        heldKeys = []
        var released: [InjectedKey] = []
        for record in held where !released.contains(record.injected) { released.append(record.injected) }
        var out: [InjectAction] = []
        for case .key(let code) in released { out.append(.keyUp(keyCode: code)) }
        for case .modifier(let m) in released { out.append(.modifierUp(m)) }
        return out
    }

    private static func release(_ injected: InjectedKey) -> InjectAction {
        switch injected {
        case .key(let code): .keyUp(keyCode: code)
        case .modifier(let m): .modifierUp(m)
        }
    }
}
