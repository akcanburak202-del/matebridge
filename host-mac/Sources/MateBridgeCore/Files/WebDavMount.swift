import Foundation

/// Addressing of the tablet's WebDAV volume on the Mac (decision 0015). The URL never carries credentials.
/// Always IPv4 loopback: `adb forward` listens on 127.0.0.1 only, so `localhost` (which may resolve to ::1) is avoided.
public enum WebDavMount {
    /// Local end of `adb forward`, tried first; when taken, adb picks a free port (`tcp:0`).
    public static let preferredLocalPort: UInt16 = 47010
    public static let host = "127.0.0.1"
    /// The tablet server serves its root under this prefix too, so the volume is named "MatePad".
    public static let volumePath = "/MatePad/"

    /// `http://127.0.0.1:<port>/MatePad/`: what NetFS mounts and what the mount table shows as the volume's source.
    public static func url(localPort: UInt16) -> URL {
        URL(string: "http://\(host):\(localPort)\(volumePath)")!
    }

    /// Whether a mount table entry (`statfs` type and `f_mntfromname`) is a WebDAV volume served through our
    /// forward on `localPort`. Any path on that host and port matches, so teardown also detaches a volume
    /// mounted from another path of the same server.
    public static func isOurs(fsType: String, mountedFrom: String, localPort: UInt16) -> Bool {
        guard fsType == "webdav", let c = URLComponents(string: mountedFrom),
              c.scheme?.lowercased() == "http", c.host == host, c.port == Int(localPort) else {
            return false
        }
        return true
    }
}
