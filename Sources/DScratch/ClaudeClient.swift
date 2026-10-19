import Foundation

enum ClaudeError: LocalizedError {
    case api(String)
    case refusal
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(let message): return message
        case .refusal: return "Claude declined to answer this request."
        case .badResponse: return "Unexpected response from the Claude API."
        }
    }
}

struct ClaudeModel: Identifiable {
    let id: String
    let name: String
}

/// Streams a single question to the Messages API over raw HTTP + SSE (there is no official Swift SDK).
enum ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    static let models = [
        ClaudeModel(id: "claude-opus-5-5", name: "Claude Opus 5.5"),
        ClaudeModel(id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5"),
        ClaudeModel(id: "claude-haiku-4-5", name: "Claude Haiku 4.5"),
    ]

    static let systemPrompt = """
        You are a helpful assistant inside D-Scratch, a personal scratch-pad app. \
        Your answer is inserted into the user's page, so write it as clean notes: \
        no preamble, and only simple Markdown (headings, bold, italics, bullet lists, inline code, code blocks). \
        When the current page is provided, use it as context.
        """

    /// Yields text as it arrives.
    static func stream(apiKey: String, model: String, question: String, pageText: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(apiKey: apiKey, model: model, question: question, pageText: pageText)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw ClaudeError.badResponse }
                    if http.statusCode != 200 {
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        throw ClaudeError.api(errorMessage(body, status: http.statusCode))
                    }
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:"),
                              let event = try? JSONSerialization.jsonObject(
                                with: Data(line.dropFirst(5).utf8)) as? [String: Any],
                              let type = event["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            let delta = event["delta"] as? [String: Any]
                            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String {
                                continuation.yield(text)
                            }
                        case "message_delta":
                            let stop = (event["delta"] as? [String: Any])?["stop_reason"] as? String
                            if stop == "refusal" { throw ClaudeError.refusal }
                            if stop == "max_tokens" { continuation.yield("\n\n[Answer cut off at the length limit.]") }
                        case "error":
                            let error = event["error"] as? [String: Any]
                            throw ClaudeError.api(error?["message"] as? String ?? "The Claude API reported an error.")
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeRequest(apiKey: String, model: String, question: String, pageText: String?) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var content = question
        if let pageText, !pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content = "Here is my current page:\n<page>\n\(pageText)\n</page>\n\n\(question)"
        }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 64000,
            "stream": true,
            "system": systemPrompt,
            "messages": [["role": "user", "content": content]],
        ]
        if model == "claude-opus-5-5" {
            // Opus 5.5 defaults to medium; set it explicitly.
            body["output_config"] = ["effort": "medium"]
        }
        if model == "claude-opus-5-5" || model == "claude-sonnet-5-5" {
            // Retry safety-classifier refusals on Anthropic's recommended fallback model.
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func errorMessage(_ body: Data, status: Int) -> String {
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 401: return "Invalid Claude API key. Check it in Settings (⌘,)."
        case 429: return "Rate limited by the Claude API. Try again shortly."
        default: return "Claude API error \(status): \(message ?? "no details")"
        }
    }
}
