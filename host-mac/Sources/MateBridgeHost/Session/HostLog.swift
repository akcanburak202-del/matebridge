import MateBridgeCore

/// Public entry to the host log (os.Logger plus the rotating `host.log`) for the thin app target.
/// Never pass device names, key characters or text in `fields`.
public enum HostLog {
    public static func log(_ level: LogLevel, component: String, event: String, fields: String = "") {
        SessionLogger(component: component).log(level, event, sessionID: 0, generation: 0, fields: fields)
    }
}
