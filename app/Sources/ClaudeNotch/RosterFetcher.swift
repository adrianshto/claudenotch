import Foundation

/// Pulls the live agent roster from the Cursor extension's GET /roster endpoint.
enum RosterFetcher {
    private struct Item: Decodable {
        let sessionId: String
        let name: String
        let state: String
        let window: String?
        let doneAt: Double?
    }

    /// Fetches the current roster (empty on any failure).
    static func fetch() async -> [Agent] {
        guard let url = URL(string: "http://127.0.0.1:39247/roster") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        guard
            let (data, _) = try? await URLSession.shared.data(for: req),
            let items = try? JSONDecoder().decode([Item].self, from: data)
        else { return [] }
        return items.map {
            Agent(id: $0.sessionId, name: $0.name,
                  state: AgentState(rawValue: $0.state) ?? .idle,
                  windowId: "", pid: 0, window: $0.window ?? "", doneAt: $0.doneAt)
        }
    }
}
