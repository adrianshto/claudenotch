import SwiftUI
import AppKit
import DynamicNotchKit

/// What the single, reused ping notch is currently showing. Swapped in only while
/// the notch is hidden (see `NotchNotifier.notify`), so a visible banner never
/// changes text under the cursor and a tap always belongs to the banner on screen.
@MainActor
final class PingModel: ObservableObject {
    @Published var title = ""
    @Published var message = ""
    @Published var systemImage = "bell.fill"
    /// Read at click time (not captured at render), so it is always the visible ping's.
    var onTap: () -> Void = {}
}

/// The reused notch's content: renders whatever `PingModel` currently holds.
struct PingView: View {
    @ObservedObject var model: PingModel

    var body: some View {
        NotchContent(title: model.title, message: model.message, systemImage: model.systemImage) {
            model.onTap()
        }
    }
}

/// Shows a transient notch notification (title + message + SF Symbol), plays a
/// sound, auto-dismisses, and runs `onTap` if the user clicks the notch item.
///
/// Window-leak fix (2026-11-17): there is exactly ONE DynamicNotch for all pings,
/// created once and reused. The old code built a fresh DynamicNotch per ping, and
/// DynamicNotchKit 1.1.0 never frees one: each instance starts a never-ending
/// screen-parameters observer Task that holds it strongly, and on every display
/// change that observer re-creates the instance's panel and orders it on screen —
/// even when the notch is hidden. So every ping ever shown came back as an
/// invisible 756×491 screen-saver-level window after any display change (642 of
/// them after a day, ~6 MB of WindowServer memory each → laggy Space swipes).
/// One reused instance caps that at one window, and `closeWindowIfIdle()` (driven
/// by `NotchWindowSweeper`) closes even that one when the notch is hidden.
///
/// Concurrency design (the stuck-ping bug, round two): every notch mutation
/// (hide-previous, expand, hide-self) runs on a single serialized pipeline —
/// each new operation awaits the previous task's completion before touching
/// the notch. A generation counter decides ownership: a task whose generation
/// is stale NEVER expands and NEVER hides — its successor, which bumped the
/// generation, is responsible for hiding whatever is on screen. The old design
/// cancelled the predecessor task mid-await, but cancellation is cooperative:
/// the cancelled task still went on to expand its notch AFTER the successor had
/// already tried to hide it → orphaned popup stuck on screen forever.
@MainActor
final class NotchNotifier: NotchSurface {
    private let model: PingModel
    private let notch: DynamicNotch<PingView, EmptyView, EmptyView>
    /// True from the moment we start expanding until the hide has fully completed —
    /// i.e. whenever the notch's window is legitimately on screen.
    private var shown = false
    private var pipeline: Task<Void, Never> = Task {}
    private var sleeper: Task<Void, Never>?
    private var generation = 0

    init() {
        let model = PingModel()
        self.model = model
        // .auto -> real notch on notched Macs, floating panel otherwise.
        notch = DynamicNotch(style: .auto) { PingView(model: model) }
    }

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

        // Wake the currently-sleeping task (if any) so the pipeline drains fast —
        // its stale generation makes it a no-op, and we take over hiding.
        sleeper?.cancel()

        let previousPipeline = pipeline
        let task = Task { [weak self] in
            await previousPipeline.value
            guard let self else { return }
            await self.hideIfShown()
            // Superseded while hiding the old one? Then a newer ping owns the
            // screen — showing now would orphan this ping the same old way.
            guard self.generation == gen else {
                Log.write("notch ping superseded before show: \(title)")
                return
            }
            // Swap the content in only now, with the notch hidden.
            self.model.title = title
            self.model.message = message
            self.model.systemImage = systemImage
            // DynamicNotchKit has no built-in tap API — the tap handler lives inside
            // the SwiftUI content (clicks land because the panel is borderless).
            self.model.onTap = { [weak self] in
                onTap()
                self?.dismiss()
            }
            self.shown = true
            await self.notch.expand()
            Log.write("notch shown: \(title)")
            // Don't let the notch panel become the key window — otherwise showing it
            // steals the text cursor from whatever app/window you're typing in. Clicks
            // still work (the tap view accepts first mouse without needing key focus).
            self.makePanelNonKey()
            try? await Task.sleep(for: .seconds(seconds))
            // Superseded (or tapped) during the wait: the successor hides us.
            guard self.generation == gen else { return }
            await self.hideIfShown()
            Log.write("notch hidden after \(Int(seconds))s: \(title)")
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
            await self.hideIfShown()
            Log.write("notch dismissed by tap")
        }
    }

    private func hideIfShown() async {
        guard shown else { return }
        await notch.hide()   // DynamicNotchKit closes and drops its panel here
        shown = false
        model.onTap = {}     // a hidden banner can't be clicked; drop the old target
    }

    private func makePanelNonKey() {
        if let panel = notch.windowController?.window as? NSPanel {
            panel.becomesKeyOnlyIfNeeded = true
        }
    }

    // MARK: - NotchSurface

    var liveWindow: NSWindow? { shown ? notch.windowController?.window : nil }

    func closeWindowIfIdle() -> Bool {
        guard !shown else {
            // A display change while a banner is up rebuilds its panel; keep the
            // never-steal-focus guarantee on the replacement too.
            makePanelNonKey()
            return false
        }
        guard let wc = notch.windowController else { return false }
        wc.close()
        notch.windowController = nil
        return true
    }
}
