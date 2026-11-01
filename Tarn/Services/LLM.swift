import Foundation

struct ToolCallDelta: Equatable {
    let index: Int
    let id: String?
    let name: String?
    let arguments: String?
}

struct StreamChunk: Equatable {
    var content: String?
    var reasoning: String?
    var toolCalls: [ToolCallDelta] = []
    var finishReason: String?
    var predictedTokens: Int?
    var predictedMs: Double?
    var error: String?
}

enum SSE {
    enum Line: Equatable { case chunk(StreamChunk), done, ignore }

    /// Parses one line of an OpenAI-style server-sent-events stream from llama-server.
    static func parse(_ line: String) -> Line {
        guard line.hasPrefix("data:") else { return .ignore }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data.isEmpty { return .ignore }
        if data == "[DONE]" { return .done }
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return .ignore }
        if let err = json["error"] {
            let msg = (err as? [String: Any])?["message"] as? String ?? (err as? String) ?? "Unknown error"
            return .chunk(StreamChunk(error: msg))
        }
        var c = StreamChunk()
        if let choice = (json["choices"] as? [[String: Any]])?.first {
            let delta = choice["delta"] as? [String: Any] ?? [:]
            c.content = delta["content"] as? String
            c.reasoning = delta["reasoning_content"] as? String
            c.finishReason = choice["finish_reason"] as? String
            for t in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let fn = t["function"] as? [String: Any]
                c.toolCalls.append(ToolCallDelta(index: t["index"] as? Int ?? 0, id: t["id"] as? String, name: fn?["name"] as? String, arguments: fn?["arguments"] as? String))
            }
        }
        if let timings = json["timings"] as? [String: Any] {
            c.predictedTokens = timings["predicted_n"] as? Int
            c.predictedMs = timings["predicted_ms"] as? Double
        }
        return .chunk(c)
    }
}

enum LLMError: LocalizedError {
    case contextOverflow
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .contextOverflow: "This conversation is too long for the AI’s memory. Start a new chat."
        case .http(let code, let body): "The AI engine answered \(code). \(body.prefix(200))"
        }
    }
}

enum LLM {
    /// Streams a chat completion from the local engine.
    static func stream(baseURL: URL, apiKey: String, body: [String: Any]) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 600
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, res) = try await URLSession.shared.bytes(for: req)
                    let status = (res as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line; if text.count > 2000 { break } }
                        if status == 400, text.range(of: "context|too long|exceed", options: [.regularExpression, .caseInsensitive]) != nil {
                            throw LLMError.contextOverflow
                        }
                        throw LLMError.http(status, text)
                    }
                    for try await line in bytes.lines {
                        switch SSE.parse(line) {
                        case .done: continuation.finish(); return
                        case .chunk(let c): continuation.yield(c)
                        case .ignore: break
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

    /// One short non-streaming completion (used for chat titles).
    static func complete(baseURL: URL, apiKey: String, body: [String: Any]) async throws -> String {
        var req = URLRequest(url: baseURL.appendingPathComponent("v1/chat/completions"), timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let msg = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return msg ?? ""
    }
}
