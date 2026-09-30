/// The command line launchd runs for the adb server. Never contains `-a`: that flag makes adb listen on every
/// interface, exposing port 5037 (full control of the tablet) to the LAN. The default is loopback only.
/// mDNS is disabled because adb's mDNS bridge aborts on some networks and we never need it.
public enum AdbServerLaunch {
    public static func command(adb: String) -> [String] {
        ["/usr/bin/env", "ADB_MDNS=0", "ADB_MDNS_AUTO_CONNECT=0", adb, "nodaemon", "server"]
    }
}
