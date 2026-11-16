import SwiftUI

/// Live state of one agent (one Claude Code session in one terminal tab).
enum AgentState: String, Codable, Sendable {
    case running, done, needsYou, idle

    var color: Color {
        switch self {
        case .running: return .green
        case .done:    return .yellow
        case .needsYou: return .red
        case .idle:    return .gray
        }
    }
    var symbol: String {
        switch self {
        case .running: return "▶"
        case .done:    return "✓"
        case .needsYou: return "●"
        case .idle:    return "○"
        }
    }
    var label: String {
        switch self {
        case .running: return "running"
        case .done:    return "done"
        case .needsYou: return "needs you"
        case .idle:    return "idle"
        }
    }
}

struct Agent: Identifiable, Equatable, Sendable {
    let id: String        // sessionId
    var name: String      // the tab name you set
    var state: AgentState
    var windowId: String
    var pid: Int
    var window: String = ""   // human label for the Cursor window (its project/folder)
    var doneAt: Double? = nil // epoch ms when it entered `done` (nil unless done)

    /// True if it finished within the last 2 minutes — rendered in a distinct hue so a
    /// fresh finish stands out from a pile of older `done` agents.
    var doneRecently: Bool {
        guard state == .done, let doneAt else { return false }
        return Date().timeIntervalSince1970 * 1000 - doneAt < 120_000
    }

    /// Dot/label color: a just-finished agent reads purple; everything else uses its
    /// state color (running green / done yellow / needs-you red / idle gray).
    var displayColor: Color {
        doneRecently ? Color(red: 0.72, green: 0.55, blue: 1.0) : state.color
    }

    /// Row priority (lower = higher up). Drives the most-urgent-first ordering so
    /// the row cap can never bury a "needs you". Idle is last (and filtered out of
    /// rows entirely — see `RosterStore.actionable`).
    var sortRank: Int {
        switch state {
        case .needsYou: return 0
        case .done:     return doneRecently ? 1 : 3
        case .running:  return 2
        case .idle:     return 4
        }
    }
}

/// The single source of truth the dashboard renders. Fed by the hub (hook +
/// extension) via `apply(_:)` on each /roster fetch.
@MainActor
final class RosterStore: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var expanded = false

    var running: Int  { agents.lazy.filter { $0.state == .running }.count }
    var done: Int     { agents.lazy.filter { $0.state == .done }.count }
    var needsYou: Int { agents.lazy.filter { $0.state == .needsYou }.count }
    var idle: Int     { agents.lazy.filter { $0.state == .idle }.count }
    var hasAny: Bool  { !agents.isEmpty }

    /// Agents that have earned a row: anything that's actually doing something
    /// (running), finished (done), or waiting on you (needsYou). Idle
    /// "opened-but-never-used" sessions are excluded — they only feed the idle
    /// count chip, so a pile of stray terminals can't bury what matters. Sorted
    /// most-urgent-first; newer finishes float above older ones.
    var actionable: [Agent] {
        agents
            .filter { $0.state != .idle }
            .sorted { a, b in
                if a.sortRank != b.sortRank { return a.sortRank < b.sortRank }
                // Total ordering: treat a missing doneAt as 0 (rather than skipping the
                // comparison) so the comparator is well-defined for every pair.
                let da = a.doneAt ?? 0, db = b.doneAt ?? 0
                if da != db { return da > db }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    func apply(_ agents: [Agent]) { self.agents = agents }
}
