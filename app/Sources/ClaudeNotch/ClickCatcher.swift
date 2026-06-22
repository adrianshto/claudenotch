import SwiftUI
import AppKit

/// A transparent AppKit click target that fires even when its window is a
/// borderless, non-activating, non-key panel — which is exactly what
/// DynamicNotchKit shows the notch in. SwiftUI's `.onTapGesture` is unreliable
/// there because gesture recognition can require the window to be key; AppKit's
/// `acceptsFirstMouse` guarantees the very first click is delivered regardless.
struct ClickCatcher: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.onClick = onClick
        return v
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }
}

final class ClickView: NSView {
    var onClick: (() -> Void)?

    // Deliver the click even when the panel isn't the active/key window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        Log.write("ClickView.mouseDown — notch clicked")
        onClick?()
    }
}
