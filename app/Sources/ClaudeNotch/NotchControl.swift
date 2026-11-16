import AppKit

/// Hub/app lifecycle controls invoked from the menu-bar menu (ClaudeNotchApp's
/// MenuBarExtra). Restart/Quit go through launchctl DIRECTLY rather than the
/// `claudenotch` CLI, because they kill this process and we need launchd — not a
/// child shell that dies with us — to do the relaunch / suppress the KeepAlive respawn.
enum NotchControl {
    private static let hubLabel = "com.claudenotch.hub"
    private static let appLabel = "com.casper.claudenotch"
    private static var uid: String { String(getuid()) }

    /// Clean reset of hub + app. Hub first (its launchctl subprocess completes), then
    /// the app last — kickstarting the app SIGKILLs us and launchd starts a fresh copy.
    static func restart() {
        Log.write("menu: restart (kickstart hub then app)")
        launchctl(["kickstart", "-k", "gui/\(uid)/\(hubLabel)"], wait: true)
        launchctl(["kickstart", "-k", "gui/\(uid)/\(appLabel)"], wait: false)
    }

    /// Actually stop both. bootout removes KeepAlive so neither respawns — a plain
    /// terminate() would just be relaunched by launchd seconds later.
    /// Also drops the `paused` flag the notify hook honors: with the hub gone, every
    /// Claude Code event would otherwise fall back to a terminal-notifier banner —
    /// quitting the notch must mean silence, not a different notification channel.
    static func quit() {
        Log.write("menu: quit (bootout both + pause hooks — won't respawn)")
        let paused = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-notch/paused")
        FileManager.default.createFile(atPath: paused.path, contents: nil)
        launchctl(["bootout", "gui/\(uid)/\(hubLabel)"], wait: true)
        launchctl(["bootout", "gui/\(uid)/\(appLabel)"], wait: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
    }

    static func openLogs() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-notch/hub.log")
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private static func launchctl(_ args: [String], wait: Bool) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        do {
            try p.run()
        } catch {
            Log.write("launchctl \(args.joined(separator: " ")) failed: \(error.localizedDescription)")
            return -1
        }
        if wait { p.waitUntilExit(); return p.terminationStatus }
        return 0
    }
}
