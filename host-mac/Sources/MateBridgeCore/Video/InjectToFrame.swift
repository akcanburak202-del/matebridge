import Foundation

/// T-323: "input injected -> first changed frame" (EN2/HA3 of the T-298 review). Pure matching logic; the Host feeds it
/// press-edge times (after the CGEvent was posted) and the arrival times of ScreenCaptureKit `complete` frames that
/// had a non-empty dirty rect. All times are host-clock microseconds. Diagnostics only: nothing here affects input
/// or video.
///
/// A sample is `first dirty frame arrival - press edge`. The screen may also change for other reasons (video, a
/// clock, an animation), which would match the wrong frame, so a press only arms a measurement when the screen was
/// still for `quietWindowUs` before it. Presses that came while the screen was busy are counted as `noisy` and give
/// no sample, and an armed press no frame answered within `timeoutUs` is counted as `timeout`. The result is an
/// approximation (a change that has nothing to do with the press right after a quiet period still matches).
public struct InjectToFrameMatcher: Sendable {
    /// The screen must have had no dirty frame for this long before a press for it to be measured.
    public static let quietWindowUs: UInt64 = 500_000
    /// An armed press that no dirty frame answered within this long is given up.
    public static let timeoutUs: UInt64 = 1_000_000

    public private(set) var pendingUs: UInt64?
    private var lastDirtyUs: UInt64?
    public private(set) var samplesUs: [UInt64] = []
    public private(set) var noisy = 0
    public private(set) var timeouts = 0
    static let maxSamples = 2048

    public init() {}

    /// A press edge (key, button, pen contact start) was posted at `nowUs`.
    public mutating func noteInjection(atUs nowUs: UInt64) {
        expire(nowUs: nowUs)
        if pendingUs != nil { return }  // an earlier press is still being measured: its frame answers both
        if let last = lastDirtyUs, nowUs >= last, nowUs - last < Self.quietWindowUs {
            noisy += 1
            return
        }
        pendingUs = nowUs
    }

    /// A `complete` frame with a non-empty dirty rect arrived at `nowUs`.
    public mutating func noteDirtyFrame(atUs nowUs: UInt64) {
        expire(nowUs: nowUs)
        if let p = pendingUs, nowUs >= p {
            if samplesUs.count < Self.maxSamples { samplesUs.append(nowUs - p) }
            pendingUs = nil
        }
        lastDirtyUs = nowUs
    }

    /// Gives up an armed press that waited too long.
    public mutating func expire(nowUs: UInt64) {
        if let p = pendingUs, nowUs >= p, nowUs - p > Self.timeoutUs {
            timeouts += 1
            pendingUs = nil
        }
    }

    public var isEmpty: Bool { samplesUs.isEmpty }

    /// Fields of `video ev=inject_to_frame`, and the window is reset. Nil without samples (the noisy and timeout
    /// counts then roll over into the next window with samples).
    public mutating func takeFields() -> String? {
        guard !samplesUs.isEmpty else { return nil }
        func ms(_ us: UInt64) -> String { String(format: "%.1f", Double(us) / 1000) }
        let fields = "n=\(samplesUs.count) p50_ms=\(ms(CadenceWindow.percentile(samplesUs, 50)))"
            + " p95_ms=\(ms(CadenceWindow.percentile(samplesUs, 95))) max_ms=\(ms(samplesUs.max() ?? 0))"
            + " noisy=\(noisy) timeout=\(timeouts)"
        samplesUs.removeAll(keepingCapacity: true)
        noisy = 0
        timeouts = 0
        return fields
    }
}

/// Thread-safe wrapper (the input queue and the capture queue share it) with the 10 s report cadence.
public final class InjectToFrameMeter: @unchecked Sendable {
    public static let reportIntervalUs: UInt64 = 10_000_000
    private let lock = NSLock()
    private var matcher = InjectToFrameMatcher()
    private var lastReportUs: UInt64?

    public init() {}

    public func noteInjection(atUs nowUs: UInt64) { lock.withLock { matcher.noteInjection(atUs: nowUs) } }
    public func noteDirtyFrame(atUs nowUs: UInt64) { lock.withLock { matcher.noteDirtyFrame(atUs: nowUs) } }

    /// The log fields when 10 s have passed since the last report and there are samples; nil otherwise.
    public func takeReport(nowUs: UInt64) -> String? {
        lock.withLock {
            guard let last = lastReportUs else { lastReportUs = nowUs; return nil }
            guard nowUs >= last, nowUs - last >= Self.reportIntervalUs else { return nil }
            matcher.expire(nowUs: nowUs)
            guard let fields = matcher.takeFields() else { return nil }
            lastReportUs = nowUs
            return fields
        }
    }
}

extension MacEvent {
    /// A press edge for T-323: a key or modifier going down (not a host autorepeat), a mouse button down, or a pen
    /// touching down. Hover, drag, release and scroll are not.
    public var isPressEdge: Bool {
        switch self {
        case .key(let k): return (k.kind == .keyDown || k.kind == .modifierDown) && !k.isRepeat
        case .mouse(let m): return m.kind == .down
        case .tabletPoint(let p): return p.kind == .down
        case .tabletProximity, .scroll, .magnify, .capsLock: return false
        }
    }
}
