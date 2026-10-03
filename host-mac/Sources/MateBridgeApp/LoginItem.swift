import Foundation
import MateBridgeCore
import MateBridgeHost
import ServiceManagement

/// "Start at login" via `SMAppService.mainApp`. Default on: registered at launch until it succeeds once; after that
/// the menu toggle is the only writer, so a user who turns it off is never overridden (`LoginItemPolicy`, T-148).
@MainActor
final class LoginItem {
    private static let firstRunKey = "loginItemFirstRunDone"
    private static let approvalHint = "Sistem Ayarları > Giriş Öğeleri'nde onay gerekli"

    /// One-line problem for the menu, nil when fine.
    private(set) var problem: String?

    /// Only a real `.app` bundle can register itself; a `swift run` binary cannot.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Reads the live status (the user may have changed it in System Settings > Login Items).
    var status: LoginItemStatus {
        guard isBundled else { return .off }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .off
        }
    }

    /// Re-reads the status for the menu: clears a stale problem, shows the approval hint when macOS wants one.
    func refresh() {
        guard isBundled else { return }
        switch SMAppService.mainApp.status {
        case .requiresApproval: problem = Self.approvalHint
        case .enabled: problem = nil
        default: if problem == Self.approvalHint { problem = nil }
        }
    }

    /// Call once at launch. `LoginItemPolicy` decides whether to register and when the first run counts as done.
    func registerOnFirstRun() { run(.launch) }

    /// A pending approval counts as requested, so toggling it cancels the registration.
    func toggle() { run(.userToggle) }

    private func run(_ trigger: LoginItemPolicy.Trigger) {
        let defaults = UserDefaults.standard
        let action = LoginItemPolicy.action(for: trigger, firstRunDone: defaults.bool(forKey: Self.firstRunKey),
                                            status: status)
        let outcome = perform(action)
        if action != .none { problem = LoginItemPolicy.problem(after: outcome) }
        if LoginItemPolicy.marksDone(trigger: trigger, action: action, outcome: outcome) {
            defaults.set(true, forKey: Self.firstRunKey)
        }
        if outcome == .succeeded && action != .none { refresh() }
    }

    private func perform(_ action: LoginItemPolicy.Action) -> LoginItemPolicy.Outcome {
        if action == .none { return .succeeded }
        let on = action == .register
        guard isBundled else {
            HostLog.log(.warning, component: "session", event: "login_item_failed", fields: "reason=not_bundled")
            return .notBundled
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            HostLog.log(.info, component: "session", event: "login_item", fields: "enabled=\(on)")
            return .succeeded
        } catch {
            HostLog.log(.warning, component: "session", event: "login_item_failed",
                        fields: "enabled=\(on) code=\((error as NSError).code)")
            return .failed(reason: error.localizedDescription)
        }
    }
}
