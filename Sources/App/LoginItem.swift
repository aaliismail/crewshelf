import AppKit
import ServiceManagement

/// Launch at login through SMAppService.mainApp (macOS 13+), for a copy of Crewshelf in /Applications or
/// ~/Applications.
enum LoginItem {
    static var allowed: Bool { launchAtLoginAllowed(bundlePath: Bundle.main.bundlePath) }

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var enabled: Bool { status == .enabled }

    static var statusText: String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notRegistered: return "not registered"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }

    /// Turn it on or off. Outside Applications nothing is registered: the notice says to move the app first.
    static func toggle(_ model: CrewshelfModel) {
        guard allowed else { return model.showNotice(.moveToApplications(Bundle.main.bundlePath)) }
        do {
            if enabled || status == .requiresApproval {
                try SMAppService.mainApp.unregister()
                model.showNotice(nil)
            } else {
                try SMAppService.mainApp.register()
                if status == .requiresApproval { model.showNotice(.loginApproval) }
            }
        } catch {
            if status == .requiresApproval { model.showNotice(.loginApproval) } else { model.showNotice(.loginError(error.localizedDescription)) }
        }
    }
}
