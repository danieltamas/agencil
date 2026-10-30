import Foundation

/// The two Ollama requests a seat needs: is the model there, and one non-streaming chat.
enum OllamaClient {
    static func problem(for seat: Seat) -> String? {
        guard let endpoint = seat.endpoint else { return "seat \(seat.name) has no endpoint" }
        guard let reply = request("\(endpoint)/api/tags", body: nil, timeout: 5),
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return "\(endpoint) down" }
        let names = models.flatMap { [$0["name"] as? String, $0["model"] as? String].compactMap { $0 } }
        return names.contains(seat.model) ? nil : "model \(seat.model) not loaded at \(endpoint)"
    }

    /// The answer text, or the reason the chat failed.
    static func chat(seat: Seat, prompt: String) -> Result<String, Refusal> {
        guard let endpoint = seat.endpoint else { return .failure(Refusal(exit: 4, message: "failed: seat \(seat.name) has no endpoint")) }
        var body: [String: Any] = ["model": seat.model, "messages": [["role": "user", "content": prompt]], "stream": false]
        if let tokens = seat.capTokens { body["options"] = ["num_predict": tokens] }
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let reply = request("\(endpoint)/api/chat", body: data, timeout: Double(seat.capSeconds)),
              let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any],
              let message = object["message"] as? [String: Any], let text = message["content"] as? String else {
            return .failure(Refusal(exit: 4, message: "failed: \(endpoint) did not answer"))
        }
        return .success(text)
    }

    private static func request(_ url: String, body: Data?, timeout: Double) -> Data? {
        guard let target = URL(string: url), ["http", "https"].contains(target.scheme) else { return nil }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { result = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        return result
    }
}
