import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifier = NotchNotifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only accessory: no dock icon, never steals focus.
        NSApp.setActivationPolicy(.accessory)
        Log.write("app launched")
    }

    /// Entry point for `open "claudenotch://notify?..."` fired by the Cursor extension.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    func testPing() {
        notifier.notify(
            title: "Claude Notch",
            message: "Test ping — click me to confirm taps work.",
            systemImage: "bell.fill"
        ) { Log.write("test ping tapped") }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "claudenotch" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func q(_ key: String) -> String { items.first { $0.name == key }?.value ?? "" }

        let name = q("name").isEmpty ? "agent" : q("name")
        let event = q("event")
        let message = q("message")
        let sessionId = q("sessionId")
        Log.write("url received: name=\(name) event=\(event) session=\(sessionId)")

        let isDone = event == "done"
        let symbol = isDone ? "checkmark.seal.fill" : "bell.fill"
        let sound = isDone ? "Glass" : "Funk"
        let body = !message.isEmpty
            ? message
            : (isDone ? "Finished — click to open." : "Needs your attention — click to jump in.")

        notifier.notify(title: name, message: body, systemImage: symbol, sound: sound) { [weak self] in
            Log.write("notch tapped — requesting focus for session=\(sessionId)")
            self?.raiseCursor()
            Focus.request(sessionId: sessionId)
        }
    }

    /// Bring Cursor to the front so the tab the extension reveals is actually
    /// visible when you click the notch from another app.
    private func raiseCursor() {
        let apps = NSWorkspace.shared.runningApplications
        // Match the MAIN Cursor app (a regular UI app) — NOT helper XPC services
        // like "CursorUIViewService" whose bundle id also contains "cursor".
        let cursor = apps.first { $0.activationPolicy == .regular && $0.localizedName == "Cursor" }
            ?? apps.first { $0.activationPolicy == .regular && ($0.bundleIdentifier?.lowercased().contains("cursor") ?? false) }
        if let cursor {
            cursor.activate(options: [.activateAllWindows])
            Log.write("raiseCursor: activated \(cursor.localizedName ?? "?") [\(cursor.bundleIdentifier ?? "?")]")
        } else {
            Log.write("raiseCursor: main Cursor app not found")
        }
    }
}
