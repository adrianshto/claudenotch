import SwiftUI
import AppKit
import DynamicNotchKit

/// Shows a transient notch notification (title + message + SF Symbol), plays a
/// sound, auto-dismisses, and runs `onTap` if the user clicks the notch item.
@MainActor
final class NotchNotifier {
    private var notch: DynamicNotch<NotchContent, EmptyView, EmptyView>?
    private var dismissTask: Task<Void, Never>?

    func notify(
        title: String,
        message: String,
        systemImage: String = "bell.fill",
        sound: String = "Glass",
        seconds: Double = 4,
        onTap: @escaping () -> Void
    ) {
        NSSound(named: sound)?.play()

        // DynamicNotchKit has no built-in tap API — the tap handler lives inside
        // the SwiftUI content (clicks land because the panel is borderless).
        let content = NotchContent(title: title, message: message, systemImage: systemImage) { [weak self] in
            onTap()
            self?.dismiss()
        }

        // .auto -> real notch on notched Macs, floating panel otherwise.
        let newNotch = DynamicNotch(style: .auto) { content }

        // Cancel the previous ping's auto-hide and remember its notch so we can
        // tear it down before showing this one. (The old bug: a ping arriving while
        // another was on screen overwrote `self.notch`, orphaning the previous notch
        // with nothing left to hide it — so it stuck on screen forever.)
        dismissTask?.cancel()
        let previous = notch
        notch = newNotch

        // One task owns this notch end-to-end: hide any previous one, expand this
        // one, wait, then hide THIS one (captured locally, so a newer ping replacing
        // `self.notch` can't leave this notch stranded).
        dismissTask = Task { [weak self] in
            await previous?.hide()
            await newNotch.expand()
            // Don't let the notch panel become the key window — otherwise showing it
            // steals the text cursor from whatever app/window you're typing in. Clicks
            // still work (the tap view accepts first mouse without needing key focus).
            if let panel = newNotch.windowController?.window as? NSPanel {
                panel.becomesKeyOnlyIfNeeded = true
            }
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await newNotch.hide()
            if self?.notch === newNotch { self?.notch = nil }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        let current = notch
        notch = nil
        Task { await current?.hide() }
    }
}
