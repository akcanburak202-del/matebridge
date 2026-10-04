import Foundation

/// Decides whether a freshly launched MateBridge may run or must exit because another copy owns the host (T-224).
/// Pure: `main.swift` (MateBridgeApp) lists the running copies via `NSRunningApplication`, sleeps for `wait` and asks
/// again. Two copies would fight over ports 47001/47002 (the later one falls back to random ports and shows up as a
/// second Bonjour service), run two USB watchers and show two menu bar icons.
public enum SingleInstancePolicy {
    /// One running process with the same bundle identifier, as `NSRunningApplication` reports it.
    public struct Instance: Equatable, Sendable {
        public let pid: Int32
        public let launchDate: Date?
        public let isTerminated: Bool

        public init(pid: Int32, launchDate: Date?, isTerminated: Bool = false) {
            self.pid = pid
            self.launchDate = launchDate
            self.isTerminated = isTerminated
        }
    }

    public enum Decision: Equatable, Sendable {
        /// No older live copy: start normally.
        case proceed
        /// An older copy is still alive (typically still quitting): sleep `ms`, re-list and decide again.
        case wait(ms: Int)
        /// An older copy stayed alive for the whole grace period: log `second_instance` and exit.
        case exit(existingPID: Int32)
    }

    /// How long a new copy waits for an older one to finish quitting (`quit` followed at once by `open`). Without the
    /// wait the new copy would exit while the old one is going away and no copy would be left.
    public static let graceMs = 5000
    public static let pollMs = 200

    /// - Parameters:
    ///   - ownPID/ownLaunchDate: this process.
    ///   - others: every process with the bundle identifier; this process is skipped by pid, so passing it is fine.
    ///   - waitedMs: total sleep so far in this launch.
    public static func decide(ownPID: Int32, ownLaunchDate: Date?, others: [Instance], waitedMs: Int) -> Decision {
        // Only an older live copy blocks. When two copies start together each sees the other, but only the younger
        // one yields, so one copy always survives.
        let blockers = others.filter {
            $0.pid != ownPID && !$0.isTerminated && isOlder($0, thanPID: ownPID, launchDate: ownLaunchDate)
        }
        guard let blocker = blockers.min(by: { $0.pid < $1.pid }) else { return .proceed }
        if waitedMs < graceMs { return .wait(ms: pollMs) }
        return .exit(existingPID: blocker.pid)
    }

    /// Earlier launch date wins; equal or unknown dates fall back to the lower pid.
    private static func isOlder(_ other: Instance, thanPID pid: Int32, launchDate: Date?) -> Bool {
        if let theirs = other.launchDate, let ours = launchDate, theirs != ours { return theirs < ours }
        return other.pid < pid
    }
}
