import AppKit

/// Notch geometry helpers for the current screen.
enum ScreenNotch {
    /// The physical notch's frame (top-center). Falls back to a menu-bar-height
    /// strip on non-notched displays.
    static func frame(for screen: NSScreen?) -> NSRect {
        guard let screen else { return .zero }
        let height = screen.safeAreaInsets.top > 0
            ? screen.safeAreaInsets.top
            : (screen.frame.maxY - screen.visibleFrame.maxY)
        let width: CGFloat
        if let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
            width = screen.frame.width - left - right
        } else {
            width = 220
        }
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
    }
}
