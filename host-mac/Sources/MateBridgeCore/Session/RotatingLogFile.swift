import Foundation

/// Size-rotated text log (`host.log`, `host.1.log`, ...). Thread-safe; failures never throw (logging must not
/// take the app down). The directory is created 0700 and files 0600. Callers must pass sanitized lines only.
public final class RotatingLogFile: @unchecked Sendable {
    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/MateBridge", isDirectory: true)
    }

    private let directory: URL
    private let baseName: String
    private let ext: String
    private let maxBytes: Int
    private let keep: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0

    /// - Parameter keep: total number of files kept (current + rotated).
    public init(directory: URL = RotatingLogFile.defaultDirectory(), fileName: String = "host.log",
                maxBytes: Int = 10 * 1024 * 1024, keep: Int = 5) {
        self.directory = directory
        let url = URL(fileURLWithPath: fileName)
        self.ext = url.pathExtension
        self.baseName = url.deletingPathExtension().lastPathComponent
        self.maxBytes = max(1, maxBytes)
        self.keep = max(1, keep)
    }

    private func url(_ index: Int) -> URL {
        let name = index == 0 ? baseName : "\(baseName).\(index)"
        return directory.appendingPathComponent(ext.isEmpty ? name : "\(name).\(ext)")
    }

    public func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        lock.lock()
        defer { lock.unlock() }
        if handle == nil { open() }
        if size > 0, size + data.count > maxBytes { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            size += data.count
        } catch {
            closeLocked()
        }
    }

    public func close() {
        lock.lock()
        closeLocked()
        lock.unlock()
    }

    private func closeLocked() {
        try? handle?.close()
        handle = nil
    }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        let file = url(0)
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: file) else { return }
        size = Int((try? h.seekToEnd()) ?? 0)
        handle = h
    }

    private func rotate() {
        closeLocked()
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
