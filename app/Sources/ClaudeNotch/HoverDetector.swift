import AppKit

/// A tiny transparent panel sitting exactly over the physical notch, used only
/// to detect when the cursor flicks to the notch (to summon the dashboard).
/// It covers just the notch footprint, so it never blocks menu-bar items.
@MainActor
final class HoverDetector {
    private let panel: NSPanel
    private let tracking = TrackingView()

    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    init() {
        let frame = ScreenNotch.frame(for: .main)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        panel.contentView = tracking

        tracking.onEnter = { [weak self] in self?.onEnter() }
        tracking.onExit = { [weak self] in self?.onExit() }
    }

    func start() { panel.orderFrontRegardless() }
}

private final class TrackingView: NSView {
    var onEnter: () -> Void = {}
    var onExit: () -> Void = {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}
