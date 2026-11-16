import AppKit
import SwiftUI
import DynamicNotchKit

/// The dashboard, rendered with the SAME engine as the transient pings
/// (DynamicNotchKit) so it gets the exact 10/10 animation. Summoned on demand
/// and retracts when dismissed — so its window is only up briefly, like a ping.
@MainActor
final class DashboardController: NotchSurface {
    private let store: RosterStore
    private let notch: DynamicNotch<RosterDashboardView, EmptyView, EmptyView>
    private(set) var shown = false
    /// True from show() until a hide has FULLY completed. Differs from `shown` while
    /// a hide is still animating, or is held open because the cursor is over the
    /// dashboard (`.keepVisible`) — closing the window then would strand
    /// DynamicNotchKit's hide and the dashboard would never expand again.
    private var windowUp = false

    init(store: RosterStore,
         onPick: @escaping (Agent) -> Void,
         onClearFinished: @escaping () -> Void) {
        self.store = store
        self.notch = DynamicNotch(hoverBehavior: [.keepVisible]) {
            RosterDashboardView(store: store, onPick: onPick, onClearFinished: onClearFinished)
        }
    }

    /// Whether the mouse is currently over the expanded dashboard (DynamicNotchKit's
    /// own hover tracking) — used to decide when to retract.
    var isHovering: Bool { notch.isHovering }

    func toggle() { shown ? hide() : show() }

    func show() {
        shown = true
        windowUp = true
        Task { await notch.expand() }
    }

    func hide() {
        shown = false
        Task {
            await notch.hide()
            if !shown { windowUp = false }   // not re-summoned meanwhile
        }
    }

    // MARK: - NotchSurface

    var liveWindow: NSWindow? { windowUp ? notch.windowController?.window : nil }

    func closeWindowIfIdle() -> Bool {
        guard !windowUp, let wc = notch.windowController else { return false }
        wc.close()
        notch.windowController = nil
        return true
    }
}
