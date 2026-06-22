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
