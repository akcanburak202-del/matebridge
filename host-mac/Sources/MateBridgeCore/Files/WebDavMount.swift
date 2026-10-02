import Foundation

/// Addressing of the tablet's WebDAV volume on the Mac (decision 0015). The URL never carries credentials.
public enum WebDavMount {
    /// Local end of `adb forward`, tried first; when taken, adb picks a free port (`tcp:0`).
    public static let preferredLocalPort: UInt16 = 47010

    /// `http://localhost:<port>/`: what NetFS mounts and what the mount table shows as the volume's source.
    public static func url(localPort: UInt16) -> URL {
        URL(string: "http://localhost:\(localPort)/")!
    }

    /// Whether a mount table entry (`statfs` type and `f_mntfromname`) is a WebDAV volume served through our
    /// forward on `localPort`.
    public static func isOurs(fsType: String, mountedFrom: String, localPort: UInt16) -> Bool {
        guard fsType == "webdav", let c = URLComponents(string: mountedFrom),
              c.scheme?.lowercased() == "http", let host = c.host?.lowercased(), c.port == Int(localPort) else {
            return false
        }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
