/// The share of the Wi-Fi link tablet files may use (decision 0035, docs/research/2026-10-05-wifi-files.md section 2,
/// PROTOCOL.md section 5). Pure and clock-free: every call carries `now` in nanoseconds (any monotonic origin), the
/// caller (the host's file proxy) sleeps for the returned wait. The numbers match the Kotlin `TokenBucket` /
/// `filesCapBytesPerSec` of the client (T-266).
///
/// Rule: the whole stream stays around 48 Mbps (about three quarters of the 66 Mbps that froze on the device), the
/// rest in MB/s (10^6 bytes): `clamp((48 - video_Mbps) / 8, 0.5, 3.0)`. 30 Mbps gives 2.25 MB/s, 15 gives 3, 60 gives
/// 0.5. An unknown video rate (`bitrate_kbps = 0`) gets 2 MB/s, not the lowest. USB keeps its own 20 MB/s cap and
/// does not use this type.
public enum FilesRateCap {
    public static let minBytesPerSec: UInt64 = 500_000
    public static let maxBytesPerSec: UInt64 = 3_000_000
    /// `STREAM_CONFIG.bitrate_kbps = 0`.
    public static let unknownVideoBytesPerSec: UInt64 = 2_000_000
    /// Bucket depth of the main lane on Wi-Fi (the USB profile uses 256 KiB).
    public static let burstBytes = 64 * 1024
    /// Small-request lane: the first 32 KiB of every exchange and direction, ~256 KB/s, depth 32 KiB.
    public static let smallLaneBytes = 32 * 1024
    public static let smallRateBytesPerSec: UInt64 = 256_000
    public static let smallBurstBytes = 32 * 1024

    /// The file budget for a video target of `videoKbps` (`STREAM_CONFIG.bitrate_kbps`), in bytes per second.
    /// Integer arithmetic: `(48 000 - kbps) / 8 * 1000 / 1000` = `(48 000 - kbps) * 125` bytes/s, clamped. (The client
    /// computes the same in floating point; the two can differ by one byte per second between the clamps, never at the
    /// table values.)
    public static func capBytesPerSec(videoKbps: UInt32) -> UInt64 {
        if videoKbps == 0 { return unknownVideoBytesPerSec }
        if videoKbps >= 48_000 { return minBytesPerSec }
        let raw = UInt64(48_000 - videoKbps) * 125
        return min(max(raw, minBytesPerSec), maxBytesPerSec)
    }
}

/// A token bucket with a rate that can change while running (decision 0035). Bytes already booked are a debt in
/// bytes, not in time: after `setRate` the debt is paid at the new rate. `reserve` returns how long the caller must
/// wait before using the bytes; the bucket never sleeps. Tokens may go negative (debt), the depth only limits what
/// idle time can save up.
public struct FilesTokenBucket: Equatable, Sendable {
    public private(set) var rate: UInt64
    public let burst: Int
    private var tokens: Double
    private var lastNs: UInt64

    public init(rateBytesPerSec: UInt64, burstBytes: Int, now: UInt64) {
        precondition(rateBytesPerSec > 0 && burstBytes > 0)
        rate = rateBytesPerSec
        burst = burstBytes
        tokens = Double(burstBytes)
        lastNs = now
    }

    private mutating func settle(_ now: UInt64) {
        guard now > lastNs else { return }  // a clock that stands still or runs backwards credits nothing
        let add = Double(now - lastNs) * Double(rate) / 1e9
        lastNs = now
        tokens = min(Double(burst), tokens + add)
    }

    /// Time before `now` is credited at the old rate; the depth and the debt in bytes stay.
    public mutating func setRate(_ bytesPerSec: UInt64, now: UInt64) {
        precondition(bytesPerSec > 0)
        settle(now)
        rate = bytesPerSec
    }

    /// Books `bytes` and returns the wait in nanoseconds, 0 when within budget.
    public mutating func reserve(_ bytes: Int, now: UInt64) -> UInt64 {
        precondition(bytes >= 0)
        settle(now)
        tokens -= Double(bytes)
        guard tokens < 0 else { return 0 }
        return UInt64(-tokens * 1e9 / Double(rate))
    }

    /// Bytes that are free right now (0 while in debt).
    public mutating func available(now: UInt64) -> Int {
        settle(now)
        return tokens > 0 ? Int(tokens) : 0
    }
}

/// How many bytes of the current exchange (one direction of one connection) already went through; the first
/// `FilesRateCap.smallLaneBytes` use the small lane. The host's proxy does not read HTTP, so it decides when an
/// exchange starts (`reset()`), for example when the direction of a connection changes.
public struct FilesRateLane: Equatable, Sendable {
    public private(set) var used = 0
    public init() {}
    public mutating func reset() { used = 0 }
    fileprivate mutating func take(_ n: Int) -> (small: Int, main: Int) {
        let small = min(n, max(0, FilesRateCap.smallLaneBytes - used))
        used += n
        return (small, n - small)
    }
}

/// The two lanes of the file cap: `main` for bulk transfer at the video-derived rate, `small` for the start of every
/// request and response so a small PROPFIND does not queue behind a big transfer's debt (8 connections of 64 KiB
/// bursts at 2 MB/s are ~250 ms). The overall ceiling is therefore main + small (~256 KB/s on top of 0.5-3 MB/s).
public struct FilesRateLimiter: Equatable, Sendable {
    public private(set) var videoKbps: UInt32
    private var main: FilesTokenBucket
    private var small: FilesTokenBucket

    public init(videoKbps: UInt32, now: UInt64) {
        self.videoKbps = videoKbps
        main = FilesTokenBucket(rateBytesPerSec: FilesRateCap.capBytesPerSec(videoKbps: videoKbps),
                                burstBytes: FilesRateCap.burstBytes, now: now)
        small = FilesTokenBucket(rateBytesPerSec: FilesRateCap.smallRateBytesPerSec,
                                 burstBytes: FilesRateCap.smallBurstBytes, now: now)
    }

    /// Current main-lane rate, bytes per second.
    public var mainBytesPerSec: UInt64 { main.rate }

    /// The video target changed (`STREAM_CONFIG.bitrate_kbps`): the main rate follows at once.
    public mutating func setVideoKbps(_ kbps: UInt32, now: UInt64) {
        videoKbps = kbps
        main.setRate(FilesRateCap.capBytesPerSec(videoKbps: kbps), now: now)
    }

    /// Books `bytes` of one exchange through `lane` and returns the wait in nanoseconds. The small part and the main
    /// part wait one after the other (the waits add up), as in the client.
    public mutating func reserve(_ bytes: Int, lane: inout FilesRateLane, now: UInt64) -> UInt64 {
        let split = lane.take(bytes)
        var wait: UInt64 = 0
        if split.small > 0 { wait += small.reserve(split.small, now: now) }
        if split.main > 0 { wait += main.reserve(split.main, now: now) }
        return wait
    }
}
