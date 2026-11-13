import AppKit
import UserNotifications

/// The soft sound and the banner (see Calm for when each is allowed). Uses UNUserNotificationCenter when macOS grants it to this
/// ad-hoc signed bundle, else `osascript display notification`.
final class Notifier {
    private var unAllowed = false
    /// What went out, for `--ctl layout`. CREWSHELF_QUIET=1 (test instances) records without playing or showing.
    private(set) var chimes = 0
    private(set) var banners: [String] = []
    private let quiet = ProcessInfo.processInfo.environment["CREWSHELF_QUIET"] == "1"

    init() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] ok, _ in
            self?.unAllowed = ok
        }
    }

    var method: String { unAllowed ? "UserNotifications" : "osascript" }

    func chime() {
        chimes += 1
        if !quiet { NSSound(named: "Tink")?.play() }
    }

    /// A banner with no sound (the sound has its own throttle).
    func banner(title: String, body: String) {
        banners = Array((banners + [title]).suffix(20))
        if !quiet { notify(title: title, body: body, sound: false) }
    }

    func notify(title: String, body: String, sound: Bool = true) {
        if sound { chime() }
        let body = bannerSafe(body), title = bannerSafe(title)
        let text = body.count > 180 ? String(body.prefix(179)) + "…" : body
        if unAllowed {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = text
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c,
                                                                         trigger: nil))
            return
        }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(esc(text))\" with title \"\(esc(title))\""
        DispatchQueue.global(qos: .utility).async { _ = run("/usr/bin/osascript", ["-e", script], timeout: 5) }
    }
}
