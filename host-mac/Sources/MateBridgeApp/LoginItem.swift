import Foundation
import MateBridgeHost
import ServiceManagement

/// "Start at login" via `SMAppService.mainApp`. Registered once on first launch (default on); after that the menu
/// toggle is the only writer, so a user who turns it off is never overridden.
@MainActor
final class LoginItem {
    private static let firstRunKey = "loginItemFirstRunDone"
    private static let approvalHint = "Sistem Ayarları > Giriş Öğeleri'nde onay gerekli"

    /// One-line problem for the menu, nil when fine.
    private(set) var problem: String?

    /// Only a real `.app` bundle can register itself; a `swift run` binary cannot.
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Reads the live status (the user may have changed it in System Settings > Login Items).
    var isEnabled: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
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

    /// Call once at launch.
    func registerOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.firstRunKey) else { return }
        defaults.set(true, forKey: Self.firstRunKey)
        if !isEnabled { set(true) }
    }

    func toggle() { set(!isEnabled) }

    private func set(_ on: Bool) {
        problem = nil
        guard isBundled else {
            problem = "Oturum açılışı yalnız MateBridge.app ile çalışır"
            HostLog.log(.warning, component: "session", event: "login_item_failed", fields: "reason=not_bundled")
            return
        }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            HostLog.log(.info, component: "session", event: "login_item", fields: "enabled=\(on)")
        } catch {
            problem = "Oturum açılışı ayarlanamadı: \(error.localizedDescription)"
            HostLog.log(.warning, component: "session", event: "login_item_failed",
                        fields: "enabled=\(on) code=\((error as NSError).code)")
            return
        }
        refresh()
    }
}
