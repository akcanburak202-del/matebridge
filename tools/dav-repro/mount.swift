// T-137 repro: mounts a WebDAV URL with the same NetFS options as the MateBridge host (TabletFilesBridge.mount),
// times it, prints the mount point, and (with --unmount) detaches it again.
//
// Usage: MB_DAV_TOKEN=... swift mount.swift <url> <mount-dir|-> [--unmount]
//   <mount-dir>: mount exactly there (MountAtMountDir); "-" lets NetFS pick a path under /Volumes like the host does.
// The token is passed only as the password argument and is never printed.
import Foundation
import NetFS

let args = CommandLine.arguments
guard args.count >= 3, let url = URL(string: args[1]) else {
    FileHandle.standardError.write("usage: swift mount.swift <url> <mount-dir|-> [--unmount]\n".data(using: .utf8)!)
    exit(2)
}
guard let token = ProcessInfo.processInfo.environment["MB_DAV_TOKEN"], !token.isEmpty else {
    FileHandle.standardError.write("MB_DAV_TOKEN not set\n".data(using: .utf8)!)
    exit(2)
}
let mountDir: URL? = args[2] == "-" ? nil : URL(fileURLWithPath: args[2], isDirectory: true)
let unmountAfter = args.contains("--unmount")

let openOptions = NSMutableDictionary()
openOptions["UIOption"] = "NoUI"
openOptions["AllowLoopback"] = true
let mountOptions = NSMutableDictionary()
mountOptions["SoftMount"] = true
if mountDir != nil { mountOptions["MountAtMountDir"] = true }

let started = Date()
var mountPoints: Unmanaged<CFArray>?
let rc = NetFSMountURLSync(url as CFURL, mountDir as CFURL?, "matebridge" as CFString, token as CFString,
                           openOptions as CFMutableDictionary, mountOptions as CFMutableDictionary, &mountPoints)
let ms = Int(Date().timeIntervalSince(started) * 1000)
let paths = (mountPoints?.takeRetainedValue() as? [String]) ?? []
print("mount rc=\(rc) ms=\(ms) path=\(paths.first ?? "-")")
if rc != 0 { exit(1) }

if let p = paths.first {
    let t1 = Date()
    let items = (try? FileManager.default.contentsOfDirectory(atPath: p)) ?? []
    print("list items=\(items.count) ms=\(Int(Date().timeIntervalSince(t1) * 1000))")
    var st = statfs()
    let t2 = Date()
    if statfs(p, &st) == 0 {
        let gib = { (blocks: UInt64) in String(format: "%.1f", Double(blocks) * Double(st.f_bsize) / 1_073_741_824) }
        print("statfs ms=\(Int(Date().timeIntervalSince(t2) * 1000)) bsize=\(st.f_bsize) total_gib=\(gib(st.f_blocks)) " +
              "free_gib=\(gib(st.f_bfree)) avail_gib=\(gib(st.f_bavail))")
    }
    let rv = try? URL(fileURLWithPath: p).resourceValues(forKeys: [.volumeSupportsVolumeSizesKey, .volumeAvailableCapacityKey])
    print("volume supports_sizes=\(rv?.volumeSupportsVolumeSizes.map { "\($0)" } ?? "nil") " +
          "available=\(rv?.volumeAvailableCapacity.map { "\($0)" } ?? "nil")")
    let t3 = Date()
    let probe = URL(fileURLWithPath: p).appendingPathComponent("Download/repro-write.txt")
    let wrote = (try? Data(count: 1_000_000).write(to: probe)) != nil
    let back = (try? Data(contentsOf: probe))?.count ?? -1
    try? FileManager.default.removeItem(at: probe)
    print("write ok=\(wrote) readback=\(back) ms=\(Int(Date().timeIntervalSince(t3) * 1000))")
    if unmountAfter {
        let r = unmount(p, 0)
        print("unmount rc=\(r) errno=\(r == 0 ? 0 : errno)")
    }
}
