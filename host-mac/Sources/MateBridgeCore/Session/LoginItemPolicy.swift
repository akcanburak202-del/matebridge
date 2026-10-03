/// When "start at login" is registered and when the one-shot first-run flag (`loginItemFirstRunDone`) is written
/// (T-148). Pure: `LoginItem` (MateBridgeApp) owns `SMAppService`, `UserDefaults` and logging, and asks this type what
/// to do.
public enum LoginItemPolicy {
    /// What started the attempt.
    public enum Trigger: Equatable, Sendable {
        /// App launch (`registerOnFirstRun`).
        case launch
        /// The user clicked the menu toggle.
        case userToggle
    }

    /// The `SMAppService.mainApp` call to make.
    public enum Action: Equatable, Sendable {
        case none
        case register
        case unregister
    }

    /// How the attempt went. `.none` counts as `.succeeded`.
    public enum Outcome: Equatable, Sendable {
        case succeeded
        /// The call threw; `reason` is the error's localized description (shown in the menu, never logged).
        case failed(reason: String)
        /// A `swift run` binary cannot register itself; only `MateBridge.app` can.
        case notBundled
    }

    /// Which call to make for `trigger`, given the persisted flag and the live status.
    public static func action(for trigger: Trigger, firstRunDone: Bool, status: LoginItemStatus) -> Action {
        switch trigger {
        case .launch:
            if firstRunDone || status.isRequested { return .none }
            return .register
        case .userToggle:
            // A pending approval counts as requested, so toggling it cancels the registration.
            return status.isRequested ? .unregister : .register
        }
    }

    /// Whether `loginItemFirstRunDone` is written after the attempt. It is written only once the default-on
    /// registration is in effect, or when the user chose explicitly; until then every launch retries.
    /// - Not bundled: nothing is persisted (a `swift run` binary cannot register).
    /// - Launch: only after a successful registration, or when the item is already requested (`.none`).
    /// - Toggle off: always, even if `unregister` threw. The user's choice wins and is never overridden.
    /// - Toggle on: only on success. A failed toggle-on is retried on the next launch, which is what the user asked for.
    public static func marksDone(trigger: Trigger, action: Action, outcome: Outcome) -> Bool {
        if outcome == .notBundled { return false }
        switch (trigger, action) {
        case (.userToggle, .unregister): return true
        default: return outcome == .succeeded
        }
    }

    /// The one-line problem for the menu after an attempt, nil when fine.
    public static func problem(after outcome: Outcome) -> String? {
        switch outcome {
        case .succeeded: return nil
        case .failed(let reason): return "Oturum açılışı ayarlanamadı: \(reason)"
        case .notBundled: return "Oturum açılışı yalnız MateBridge.app ile çalışır"
        }
    }
}
