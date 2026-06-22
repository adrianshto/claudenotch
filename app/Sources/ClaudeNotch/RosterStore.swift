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
}

/// The single source of truth the dashboard renders. Fed by the hub (hook +
/// extension) later; for now it can load fake data so we can see the UI.
@MainActor
final class RosterStore: ObservableObject {
    @Published var agents: [Agent] = []
    @Published var expanded = false

    var running: Int  { agents.lazy.filter { $0.state == .running }.count }
    var done: Int     { agents.lazy.filter { $0.state == .done }.count }
    var needsYou: Int { agents.lazy.filter { $0.state == .needsYou }.count }
    var hasAny: Bool  { !agents.isEmpty }

    func apply(_ agents: [Agent]) { self.agents = agents }

    func loadFake() {
        agents = [
            Agent(id: "1", name: "api-server", state: .running,  windowId: "w1", pid: 1),
            Agent(id: "2", name: "worker",     state: .running,  windowId: "w1", pid: 2),
            Agent(id: "3", name: "frontend",   state: .done,     windowId: "w1", pid: 3),
            Agent(id: "4", name: "db-migrate", state: .needsYou, windowId: "w1", pid: 4),
        ]
    }
}
