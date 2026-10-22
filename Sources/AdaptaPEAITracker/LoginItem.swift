import Observation
import ServiceManagement

/// Wraps SMAppService so the app starts in the background at login.
/// Registers once on first launch; after that the user's toggle wins.
@Observable
@MainActor
final class LoginItem {
    private static let autoRegisteredKey = "didAutoRegisterLoginItem"

    private(set) var status: SMAppService.Status = .notRegistered
    private(set) var lastError: String?

    var isEnabled: Bool { status == .enabled }
    /// Registered but blocked in System Settings › General › Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    init() {
        refresh()
        if !UserDefaults.standard.bool(forKey: Self.autoRegisteredKey) {
            setEnabled(true)
            // Mark only after success so a failed first attempt retries next launch.
            if status != .notRegistered {
                UserDefaults.standard.set(true, forKey: Self.autoRegisteredKey)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled && needsApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Fails when run unbundled (`swift run`); only the .app bundle can register.
            lastError = error.localizedDescription
        }
        refresh()
    }

    /// Call when the panel opens: the user may have changed it in System Settings.
    func refresh() {
        status = SMAppService.mainApp.status
    }
}
