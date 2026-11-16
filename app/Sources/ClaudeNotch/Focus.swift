import Foundation

/// Tells the Cursor extension to reveal + focus the tab for a given session.
enum Focus {
    static func request(sessionId: String) {
        guard !sessionId.isEmpty,
              let url = URL(string: "http://127.0.0.1:39247/focus") else {
            Log.write("focus skipped — empty sessionId")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["sessionId": sessionId])
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error {
                Log.write("focus POST error: \(error.localizedDescription)")
            } else if let http = response as? HTTPURLResponse {
                Log.write("focus POST sent (status \(http.statusCode)) session=\(sessionId)")
            }
        }.resume()
    }
}

/// Hub control actions driven from the dashboard.
enum Hub {
    private struct ClearResponse: Decodable {
        let removed: Int?
        let roster: [RosterFetcher.Item]?
    }

    /// Asks the hub to drop all finished/idle sessions ("Clear finished") and returns
    /// the authoritative post-clear roster so the caller can refresh the dashboard in
    /// one round-trip. Returns nil if the request failed (so the caller can leave the
    /// current roster untouched rather than blanking the notch).
    static func clearFinished() async -> [Agent]? {
        guard let url = URL(string: "http://127.0.0.1:39247/clear") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 2
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [:])
        guard
            let (data, resp) = try? await URLSession.shared.data(for: req),
            let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else {
            Log.write("clear POST failed")
            return nil
        }
        Log.write("clear POST sent")
        let decoded = try? JSONDecoder().decode(ClearResponse.self, from: data)
        return RosterFetcher.agents(from: decoded?.roster ?? [])
    }
}
