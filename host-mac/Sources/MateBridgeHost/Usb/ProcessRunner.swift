import Darwin
import Foundation

/// Runs a short-lived child process with a hard deadline, so a hung adb or launchctl can never wedge the caller.
/// Blocking: call it from a background queue, never the main thread.
struct ProcessRunner: Sendable {
    struct Result: Sendable {
        /// nil when the process could not be launched or was killed for exceeding the deadline.
        var status: Int32?
        var output: String
        var timedOut: Bool
        var succeeded: Bool { status == 0 }
    }

    var environment: [String: String] = [:]

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in environment { env[k] = v }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let buffer = LockedBuffer()
        let eof = DispatchGroup()
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eof.leave()
            } else {
                buffer.append(data)
            }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do { try process.run() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: nil, output: "", timedOut: false)
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        // A grandchild holding the pipe open must not block us: give the reader a moment, then move on.
        if eof.wait(timeout: .now() + 0.5) == .timedOut { pipe.fileHandleForReading.readabilityHandler = nil }
        return Result(status: timedOut ? nil : process.terminationStatus, output: buffer.string, timedOut: timedOut)
    }
}

private final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Plain TCP connect to loopback with a short deadline: "is something listening there?" without spawning anything.
enum LoopbackProbe {
    static func isListening(port: UInt16, timeout: TimeInterval = 0.5) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
