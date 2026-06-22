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
        let notch = DynamicNotch(style: .auto) { content }
        self.notch = notch

        Task {
            await notch.expand()
            dismissTask?.cancel()
            dismissTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                await self?.notch?.hide()
            }
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        Task { await notch?.hide() }
    }
}
