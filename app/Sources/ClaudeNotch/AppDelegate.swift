import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifier = NotchNotifier()
    private let roster = RosterStore()
    private var dashboard: DashboardController!
    private var detector: HoverDetector!
    private var detectorHovered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only accessory: no dock icon, never steals focus.
        NSApp.setActivationPolicy(.accessory)
        dashboard = DashboardController(store: roster) { [weak self] agent in
            guard let self else { return }
            Log.write("dashboard pick: \(agent.name) session=\(agent.id) → focus")
            self.raiseCursor()
            Focus.request(sessionId: agent.id)
            self.dashboard.hide()
        }

        // Summon-on-hover: flick the cursor to the notch → fetch the live roster
        // and drop the dashboard down.
        detector = HoverDetector()
        detector.onEnter = { [weak self] in
            guard let self else { return }
            self.detectorHovered = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.roster.apply(await RosterFetcher.fetch())
                self.dashboard.show()
                self.watchForRetract()
            }
        }
        detector.onExit = { [weak self] in self?.detectorHovered = false }
        detector.start()

        Log.write("app launched")
    }

    /// Retract the dashboard once the cursor is neither over the notch nor the
    /// expanded dashboard. Polls briefly so moving from notch → list doesn't hide it.
    private func watchForRetract() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.dashboard.shown else { return }
                if self.detectorHovered || self.dashboard.isHovering {
                    self.watchForRetract()        // still active → keep watching
                } else {
                    self.dashboard.hide()
                }
            }
        }
    }

    /// Demo: populate fake agents and show the dashboard so we can see the animation.
    func showDashboardDemo() {
        roster.loadFake()
        dashboard.show()
    }

    func hideDashboard() { dashboard.hide() }

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

        // Dev/demo trigger: `open "claudenotch://dashboard"` toggles the dashboard.
        if url.host == "dashboard" {
            Log.write("url received: dashboard toggle (shown=\(dashboard.shown))")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.roster.apply(await RosterFetcher.fetch())
                self.dashboard.toggle()
            }
            return
        }

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
