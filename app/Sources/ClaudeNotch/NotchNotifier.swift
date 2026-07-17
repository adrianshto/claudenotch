import SwiftUI
import AppKit
import DynamicNotchKit

/// Shows a transient notch notification (title + message + SF Symbol), plays a
/// sound, auto-dismisses, and runs `onTap` if the user clicks the notch item.
///
/// Concurrency design (the stuck-ping bug, round two): every notch mutation
/// (hide-previous, expand, hide-self) runs on a single serialized pipeline —
/// each new operation awaits the previous task's completion before touching
/// any DynamicNotch. A generation counter decides ownership: a task whose
/// generation is stale NEVER expands and NEVER hides — its successor, which
/// bumped the generation, is responsible for hiding whatever is on screen
/// (`current`). The old design cancelled the predecessor task mid-await, but
/// cancellation is cooperative: the cancelled task still went on to expand its
/// notch AFTER the successor had already tried to hide it → orphaned popup
/// stuck on screen forever, unreachable by dismiss().
@MainActor
final class NotchNotifier {
    private var current: DynamicNotch<NotchContent, EmptyView, EmptyView>?
    private var pipeline: Task<Void, Never> = Task {}
    private var sleeper: Task<Void, Never>?
    private var generation = 0

    func notify(
        title: String,
        message: String,
        systemImage: String = "bell.fill",
        sound: String = "Glass",
        seconds: Double = 4,
        onTap: @escaping () -> Void
    ) {
        NSSound(named: sound)?.play()

        generation += 1
        let gen = generation

        // DynamicNotchKit has no built-in tap API — the tap handler lives inside
        // the SwiftUI content (clicks land because the panel is borderless).
        let content = NotchContent(title: title, message: message, systemImage: systemImage) { [weak self] in
            onTap()
            self?.dismiss()
        }

        // .auto -> real notch on notched Macs, floating panel otherwise.
        let newNotch = DynamicNotch(style: .auto) { content }

        // Wake the currently-sleeping task (if any) so the pipeline drains fast —
        // its stale generation makes it a no-op, and we take over hiding `current`.
        sleeper?.cancel()

        let previousPipeline = pipeline
        let task = Task { [weak self] in
            await previousPipeline.value
            guard let self else { return }
            await self.current?.hide()
            // Superseded while hiding the old one? Then a newer ping owns the
            // screen — showing now would orphan this notch the same old way.
            guard self.generation == gen else {
                Log.write("notch ping superseded before show: \(title)")
                return
            }
            self.current = newNotch
            await newNotch.expand()
            Log.write("notch shown: \(title)")
            // Don't let the notch panel become the key window — otherwise showing it
            // steals the text cursor from whatever app/window you're typing in. Clicks
            // still work (the tap view accepts first mouse without needing key focus).
            if let panel = newNotch.windowController?.window as? NSPanel {
                panel.becomesKeyOnlyIfNeeded = true
            }
            try? await Task.sleep(for: .seconds(seconds))
            // Superseded (or tapped) during the wait: the successor hides us.
            guard self.generation == gen else { return }
            await newNotch.hide()
            Log.write("notch hidden after \(Int(seconds))s: \(title)")
            if self.current === newNotch { self.current = nil }
        }
        pipeline = task
        sleeper = task
    }

    func dismiss() {
        generation += 1   // supersede any in-flight show/sleep — we own the hide now
        sleeper?.cancel()
        let previousPipeline = pipeline
        pipeline = Task { [weak self] in
            await previousPipeline.value
            guard let self else { return }
            await self.current?.hide()
            Log.write("notch dismissed by tap")
            self.current = nil
        }
    }
}
