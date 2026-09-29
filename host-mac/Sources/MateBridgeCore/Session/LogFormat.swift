/// Formats a runtime log line per docs/LOGGING.md:
/// `<mono_ms> <LEVEL> <component> sid=<session> gen=<n> ev=<event_name> key=value ...`
public enum LogFormat {
    public static func line(monoMs: UInt64, level: LogLevel, component: String, sessionID: UInt32,
                            generation: UInt16, event: String, fields: String = "") -> String {
        var s = "\(monoMs) \(level.rawValue) \(component) sid=\(sessionID) gen=\(generation) ev=\(event)"
        if !fields.isEmpty { s += " " + fields }
        return s
    }
}
