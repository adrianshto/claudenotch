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
    var hasAny: Bool  { !agents.isEmpty }

    func apply(_ agents: [Agent]) { self.agents = agents }
}
