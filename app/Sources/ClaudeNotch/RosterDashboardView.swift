import SwiftUI

/// Expanded content for the dashboard notch. DynamicNotchKit draws the notch
/// shell + animation around this; we just provide the agent roster.
///
/// Design rules (so the notch can't become an unreadable session graveyard):
///   • Only *actionable* agents get a row — needs-you, running, just-finished.
///     Idle "opened-but-never-used" sessions live only in the count chip.
///   • Rows are priority-sorted (most urgent first) and capped at `maxRows`, with
///     a "+N more" line for the overflow. The notch physically cannot outgrow the
///     screen, no matter how many chats are open. (No scrolling — by design.)
///   • A "Clear finished" control drops the done pile on demand.
struct RosterDashboardView: View {
    @ObservedObject var store: RosterStore
    var onPick: (Agent) -> Void
    var onClearFinished: () -> Void

    /// Hard cap on visible rows. With idle already filtered out, ~6 actionable rows
    /// is almost always enough; the rest collapse into the "+N more" line. Kept low so
    /// the panel stays comfortably within screen height even in the worst case.
    private let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Summary chips — the idle count lives here (and only here).
            HStack(spacing: 14) {
                count(.needsYou, store.needsYou)
                count(.running, store.running)
                count(.done, store.done)
                count(.idle, store.idle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))

            let rows = store.actionable
            if rows.isEmpty {
                Text(emptyMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 4)
            } else {
                ForEach(rows.prefix(maxRows)) { agent in
                    AgentRow(agent: agent) { onPick(agent) }
                }
                if rows.count > maxRows {
                    Text("+\(rows.count - maxRows) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 10)
                        .padding(.top, 1)
                }
            }

            if store.done > 0 {
                ClearButton(label: "Clear finished", onTap: onClearFinished)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
    }

    /// Shown when nothing is actionable — distinguishes "all quiet" from "you have
    /// idle terminals sitting around" so the empty notch still says something useful.
    private var emptyMessage: String {
        store.idle > 0 ? "Nothing needs you · \(store.idle) idle" : "No active agents"
    }

    private func count(_ state: AgentState, _ n: Int) -> some View {
        HStack(spacing: 5) {
            Text(state.symbol).foregroundStyle(n > 0 ? state.color : .white.opacity(0.25))
            Text("\(n)").foregroundStyle(n > 0 ? .white : .white.opacity(0.35))
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    var onPick: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(agent.displayColor).frame(width: 7, height: 7)
            Text(agent.name)
                .foregroundStyle(.white)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(agent.doneRecently ? "just done" : agent.state.label)
                .foregroundStyle(agent.doneRecently ? agent.displayColor : .white.opacity(0.5))
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.001))   // keep row fully hit-testable
        .contentShape(Rectangle())
        .overlay(ClickCatcher(onClick: onPick))    // click row → focus that tab
    }
}

/// A small text button styled to live inside the dashboard's padded content (not a
/// flush-bottom footer — those get clipped by the notch's rounded mask).
private struct ClearButton: View {
    let label: String
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 10.5))
            Text(label)
                .font(.system(size: 11, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.5))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .overlay(ClickCatcher(onClick: onTap))
    }
}
