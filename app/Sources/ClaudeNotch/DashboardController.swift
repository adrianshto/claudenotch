import AppKit
import SwiftUI
import DynamicNotchKit

/// The dashboard, rendered with the SAME engine as the transient pings
/// (DynamicNotchKit) so it gets the exact 10/10 animation. Summoned on demand
/// and retracts when dismissed — so its window is only up briefly, like a ping.
@MainActor
final class DashboardController {
    private let store: RosterStore
    private let notch: DynamicNotch<RosterDashboardView, EmptyView, EmptyView>
    private(set) var shown = false

    init(store: RosterStore, onPick: @escaping (Agent) -> Void) {
        self.store = store
        self.notch = DynamicNotch(hoverBehavior: [.keepVisible]) {
            RosterDashboardView(store: store, onPick: onPick)
        }
    }

    /// Whether the mouse is currently over the expanded dashboard (DynamicNotchKit's
    /// own hover tracking) — used to decide when to retract.
    var isHovering: Bool { notch.isHovering }

    func toggle() { shown ? hide() : show() }

    func show() {
        shown = true
        Task { await notch.expand() }
    }

    func hide() {
        shown = false
        Task { await notch.hide() }
    }
}
