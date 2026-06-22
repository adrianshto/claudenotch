import SwiftUI

/// Expanded content for the dashboard notch. DynamicNotchKit draws the notch
/// shell + animation around this; we just provide the agent roster.
struct RosterDashboardView: View {
    @ObservedObject var store: RosterStore
    var onPick: (Agent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 16) {
                count(.running, store.running)
                count(.done, store.done)
                count(.needsYou, store.needsYou)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))

            if store.hasAny {
                ForEach(store.agents) { agent in
                    AgentRow(agent: agent) { onPick(agent) }
                }
            } else {
                Text("No active agents")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: 300, alignment: .leading)
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
            Circle().fill(agent.state.color).frame(width: 7, height: 7)
            Text(agent.name)
                .foregroundStyle(.white)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 16)
            Text(agent.state.label)
                .foregroundStyle(.white.opacity(0.5))
                .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.001))   // keep row fully hit-testable
        .contentShape(Rectangle())
        .overlay(ClickCatcher(onClick: onPick))    // click row → focus that tab
    }
}
