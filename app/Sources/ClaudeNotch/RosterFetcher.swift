import Foundation

/// Pulls the live agent roster from the hub's GET /roster endpoint.
enum RosterFetcher {
    /// One roster row as the hub serializes it. Shared so other hub responses that
    /// embed a roster (e.g. POST /clear) can decode with the same shape.
    struct Item: Decodable {
        let sessionId: String
        let name: String
        let state: String
        let window: String?
        let doneAt: Double?
    }

    /// Maps decoded rows into the app's Agent model.
    static func agents(from items: [Item]) -> [Agent] {
        items.map {
            Agent(id: $0.sessionId, name: $0.name,
                  state: AgentState(rawValue: $0.state) ?? .idle,
                  windowId: "", pid: 0, window: $0.window ?? "", doneAt: $0.doneAt)
        }
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
        return agents(from: items)
    }
}
