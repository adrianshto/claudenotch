import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notifier = NotchNotifier()
    private let roster = RosterStore()
    private var dashboard: DashboardController!
    private var detector: HoverDetector!
    private var sweeper: NotchWindowSweeper!
    private var detectorHovered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menubar-only accessory: no dock icon, never steals focus.
        NSApp.setActivationPolicy(.accessory)
        // "Quiet the window I'm working in" defaults ON (suppress pings for the focused window).
        UserDefaults.standard.register(defaults: ["focusMute": true])
        // No system permissions needed: window-raising is done by the Cursor extension
        // (`cursor --reuse-window <folder>`), which we reach via the focus POST below.
        dashboard = DashboardController(
            store: roster,
            onPick: { [weak self] agent in
                guard let self else { return }
                Log.write("dashboard pick: \(agent.name) session=\(agent.id) window=\(agent.window) → focus")
                Focus.request(sessionId: agent.id)
                self.dashboard.hide()
            },
            onClearFinished: { [weak self] in
                Log.write("dashboard: clear finished")
                Task { @MainActor in
                    guard let self else { return }
                    // Apply the authoritative roster the hub returns; on failure (nil)
                    // leave the dashboard as-is rather than blanking it.
                    if let fresh = await Hub.clearFinished() {
                        self.roster.apply(fresh)
                    }
                }
            }
        )

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

        // Close notch windows DynamicNotchKit leaves on screen after display changes
        // (see NotchWindowSweeper) — what used to pile up into hundreds of windows.
        sweeper = NotchWindowSweeper(surfaces: [notifier, dashboard])
        sweeper.start()

        // Pull pings from the extension instead of being launched with a URL (which would
        // foreground us and steal key focus from whatever the user is typing).
        startPingPolling()

        Log.write("app launched")
    }

    // MARK: - Ping long-poll (extension → app, focus-safe)

    private struct PingItem: Decodable, Sendable {
        let name: String
        let event: String
        let message: String?
        let sessionId: String
        let window: String?
        let focused: Bool?
        let ts: Double?
    }

    /// Continuously long-poll GET /pings. The request parks on the server until a ping
    /// arrives (or ~25s), so delivery is effectively instant with no busy polling.
    private func startPingPolling() {
        Task { @MainActor [weak self] in
            while true {
                guard self != nil else { return }
                let pings = await Self.fetchPings()
                guard let self else { return }
                for p in pings { self.handlePing(p) }
                if pings.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }  // gentle gap on timeout/error
            }
        }
    }

    private static func fetchPings() async -> [PingItem] {
        guard let url = URL(string: "http://127.0.0.1:39247/pings") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        guard
            let (data, _) = try? await URLSession.shared.data(for: req),
            let items = try? JSONDecoder().decode([PingItem].self, from: data)
        else { return [] }
        return items
    }

    private func handlePing(_ p: PingItem) {
        // Drop stale pings (e.g. queued while the app was down) so we don't pop a notch
        // for something that finished minutes ago.
        if let ts = p.ts, Date().timeIntervalSince1970 * 1000 - ts > 30_000 { return }

        // "Quiet the window I'm working in": if on and this agent's window was focused, skip.
        let focused = p.focused ?? false
        let focusMute = UserDefaults.standard.object(forKey: "focusMute") as? Bool ?? true
        if focused && focusMute {
            Log.write("ping suppressed — focus-mute on, window focused: \(p.name) window=\(p.window ?? "")")
            return
        }

        let isDone = p.event == "done"
        let symbol = isDone ? "checkmark.seal.fill" : "bell.fill"
        let sound = isDone ? "Glass" : "Funk"
        let body = (p.message?.isEmpty == false)
            ? p.message!
            : (isDone ? "Finished — click to open." : "Needs your attention — click to jump in.")
        let sessionId = p.sessionId, window = p.window ?? ""
        notifier.notify(title: p.name, message: body, systemImage: symbol, sound: sound) {
            Log.write("notch tapped — requesting focus for session=\(sessionId) window=\(window)")
            Focus.request(sessionId: sessionId)
        }
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

    /// Dev entry point for `open "claudenotch://dashboard"` (pings come via long-poll now).
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

    /// Menu action: clear finished/idle sessions on the hub, then refresh the store so
    /// a subsequently-summoned dashboard reflects it immediately.
    func clearFinished() {
        Log.write("menu: clear finished")
        Task { @MainActor in
            if let fresh = await Hub.clearFinished() { self.roster.apply(fresh) }
        }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "claudenotch" else { return }

        // Dev trigger: `open "claudenotch://dashboard"` toggles the dashboard.
        if url.host == "dashboard" {
            Log.write("url received: dashboard toggle (shown=\(dashboard.shown))")
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.roster.apply(await RosterFetcher.fetch())
                self.dashboard.toggle()
            }
        }
    }
}
