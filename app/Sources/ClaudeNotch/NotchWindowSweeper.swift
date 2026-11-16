import AppKit

/// A notch-shaped UI (ping or dashboard) built on DynamicNotchKit.
@MainActor
protocol NotchSurface: AnyObject {
    /// The window that is legitimately on screen right now; nil while hidden.
    var liveWindow: NSWindow? { get }
    /// Close the surface's window if the surface is hidden. Returns true if it closed one.
    func closeWindowIfIdle() -> Bool
}

/// Keeps the app's notch windows from piling up in the WindowServer.
///
/// DynamicNotchKit 1.1.0 rebuilds each DynamicNotch's panel on every
/// `didChangeScreenParametersNotification` and orders it on screen, even when the
/// notch is hidden. Those panels are invisible (screen-saver level, transparent)
/// but the WindowServer still keeps and composites every one of them, on every
/// Space. With one reused DynamicNotch per surface that's at most one such window
/// per surface; shortly after each display change this:
///   1. closes each surface's panel if that surface is hidden, and
///   2. takes off screen any other visible screen-saver-level window in the app —
///      only DynamicNotchKit panels live at that level, so anything not owned by a
///      shown surface is an orphan.
/// Each closure is logged, so a regression would be visible in app.log.
@MainActor
final class NotchWindowSweeper {
    private let surfaces: [NotchSurface]
    private var observer: NSObjectProtocol?

    init(surfaces: [NotchSurface]) {
        self.surfaces = surfaces
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // DynamicNotchKit rebuilds its panels from its own observer of this same
            // notification; give it a moment so we sweep up after it, not before.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainActor.assumeIsolated { _ = self?.sweep(reason: "display change") }
            }
        }
    }

    @discardableResult
    func sweep(reason: String) -> Int {
        var closed = 0
        for surface in surfaces where surface.closeWindowIfIdle() { closed += 1 }

        // Backstop: with one reused DynamicNotch per surface this should never find
        // anything. Taking the window off screen is what relieves the WindowServer;
        // close() it only when AppKit won't also release it on close (Swift still
        // holds a reference → over-release crash).
        var orphans = 0
        let live = surfaces.compactMap(\.liveWindow)
        for window in NSApp.windows
        where window.level == .screenSaver
            && window.isVisible
            && !live.contains(where: { $0 === window }) {
            window.orderOut(nil)
            if !window.isReleasedWhenClosed { window.close() }
            orphans += 1
        }
        if closed + orphans > 0 {
            Log.write("window sweep (\(reason)): closed \(closed) hidden notch window(s), \(orphans) orphan(s)")
        }
        return closed + orphans
    }
}
