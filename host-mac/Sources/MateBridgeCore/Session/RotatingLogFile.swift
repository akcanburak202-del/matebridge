import Foundation

/// Size-rotated text log (`host.log`, `host.1.log`, ...). Thread-safe; failures never throw (logging must not
/// take the app down). The directory is 0700 and files 0600 (tightened if they already existed).
/// Callers must pass sanitized lines only.
///
/// `append` never touches the disk: it puts the line into a bounded buffer (oldest line dropped when full,
/// counted in `droppedLines`) and a dedicated serial queue writes it. So a slow disk can never block the caller
/// (the session queue).
public final class RotatingLogFile: @unchecked Sendable {
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MateBridge", isDirectory: true)
    }

    private let directory: URL
    private let baseName: String
    private let ext: String
    private let maxBytes: Int
    private let keep: Int
    private let maxPendingLines: Int
    private let writer = DispatchQueue(label: "dev.matebridge.logfile", qos: .utility)

    private let lock = NSLock()  // guards the three fields below
    private var pending: [String] = []
    private var dropped = 0
    private var drainScheduled = false

    // Touched only on `writer`.
    private var handle: FileHandle?
    private var size = 0
    private var reportedDropped = 0

    /// - Parameters:
    ///   - keep: total number of files kept (current + rotated).
    ///   - maxPendingLines: lines waiting for the writer; beyond that the oldest are dropped.
    public init(directory: URL = RotatingLogFile.defaultDirectory(), fileName: String = "host.log",
                maxBytes: Int = 10 * 1024 * 1024, keep: Int = 5, maxPendingLines: Int = 2048) {
        self.directory = directory
        let url = URL(fileURLWithPath: fileName)
        self.ext = url.pathExtension
        self.baseName = url.deletingPathExtension().lastPathComponent
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
        self.maxPendingLines = max(1, maxPendingLines)
    }

    /// Lines discarded because the writer could not keep up.
    public var droppedLines: Int { lock.withLock { dropped } }

    private func url(_ index: Int) -> URL {
        let name = index == 0 ? baseName : "\(baseName).\(index)"
        return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    /// Non-blocking.
    public func append(_ line: String) {
        let schedule: Bool = lock.withLock {
            pending.append(line)
            if pending.count > maxPendingLines {
                let extra = pending.count - maxPendingLines
                pending.removeFirst(extra)
                dropped += extra
            }
            let needed = !drainScheduled
            drainScheduled = true
            return needed
        }
        if schedule { writer.async { [self] in drain() } }
    }

    /// Writes everything buffered and closes the file (it reopens on the next append). Blocks until done.
    public func close() {
        writer.sync {
            drain()
            try? handle?.close()
            handle = nil
        }
    }

    // MARK: Writer queue only

    private func drain() {
        while true {
            let (lines, droppedTotal): ([String], Int) = lock.withLock {
                if pending.isEmpty { drainScheduled = false; return ([], dropped) }
                let taken = pending
                pending = []
                return (taken, dropped)
            }
            if lines.isEmpty { return }
            if handle == nil { open() }
            if droppedTotal > reportedDropped {
                write("0 W log dropped_lines total=\(droppedTotal)")
                reportedDropped = droppedTotal
            }
            for line in lines { write(line) }
        }
    }

    private func write(_ line: String) {
        let data = Data((line + "\n").utf8)
        if size > 0, size + data.count > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            try? handle.close()
            self.handle = nil
        }
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = url(0)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        size = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: url(keep - 1))
        if keep > 1 {
            for i in stride(from: keep - 2, through: 0, by: -1) {
                let from = url(i)
                if fm.fileExists(atPath: from.path) { try? fm.moveItem(at: from, to: url(i + 1)) }
            }
        }
        size = 0
        open()
    }
}
