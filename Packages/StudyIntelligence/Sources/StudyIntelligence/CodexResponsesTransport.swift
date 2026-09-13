import AnyLanguageModel
import Foundation

enum CodexResponsesTransport {
    static func round(_ payload: SloppyInferenceRequest, auth: CodexAuthorization, session: URLSession,
                      onText: (@Sendable (String) -> Void)?, retry: Bool = true) async throws -> SloppyInferenceResponse {
        let credentials = try await auth.credentials()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/responses")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = credentials.accountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-ID") }
        request.httpBody = try body(payload)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 401, retry {
            _ = try await auth.credentials(forceRefresh: true)
            return try await round(payload, auth: auth, session: session, onText: onText, retry: false)
        }
        guard response.statusCode == 200 else { throw ModelConnectionError.message("Codex вернул HTTP \(response.statusCode). Проверьте авторизацию в настройках.") }
        var parser = CodexResponseAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            try parser.consume(line)
            if parser.textChanged { onText?(parser.text) }
            if parser.completed { return .init(text: parser.text, toolCalls: parser.calls) }
        }
        throw URLError(.networkConnectionLost)
    }

    static func body(_ payload: SloppyInferenceRequest) throws -> Data {
        var input: [[String: Any]] = []
        var instructions: [String] = []
        for entry in payload.transcript {
            switch entry {
            case .instructions(let value): instructions.append(text(value.segments))
            case .prompt(let value):
                input.append(["type": "message", "role": "user", "content": try segments(value.segments, role: "user")])
            case .response(let value):
                input.append(["type": "message", "role": "assistant", "content": try segments(value.segments, role: "assistant")])
            case .toolCalls(let calls):
                for call in calls {
                    input.append(["type": "function_call", "call_id": call.id, "name": call.toolName, "arguments": call.arguments.jsonString])
                }
            case .toolOutput(let output):
                // Image tool outputs are represented as a following user image message.
                input.append(["type": "function_call_output", "call_id": output.id, "output": text(output.segments)])
                let images = output.segments.filter { if case .image = $0 { true } else { false } }
                if !images.isEmpty { input.append(["type": "message", "role": "user", "content": try segments(images, role: "user")]) }
            }
        }
        let tools: [[String: Any]] = try payload.tools.map { tool in
            let parameters = try JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.parameters))
            return ["type": "function", "name": tool.name, "description": tool.description, "parameters": parameters]
        }
        return try JSONSerialization.data(withJSONObject: [
            "model": payload.model, "store": false, "stream": true,
            "instructions": instructions.joined(separator: "\n"), "input": input, "tools": tools,
        ])
    }

    private static func text(_ segments: [Transcript.Segment]) -> String {
        segments.compactMap { segment in
            switch segment {
            case .text(let value): value.content
            case .structure(let value): value.content.jsonString
            case .image: nil
            }
        }.joined(separator: "\n")
    }
    private static func segments(_ segments: [Transcript.Segment], role: String) throws -> [[String: Any]] {
        try segments.map { segment in
            switch segment {
            case .text(let value): return ["type": role == "assistant" ? "output_text" : "input_text", "text": value.content]
            case .structure(let value): return ["type": role == "assistant" ? "output_text" : "input_text", "text": value.content.jsonString]
            case .image(let image):
                switch image.source {
                case .data(let data, let mimeType): return ["type": "input_image", "image_url": "data:\(mimeType);base64,\(data.base64EncodedString())"]
                case .url(let url): return ["type": "input_image", "image_url": url.absoluteString]
                @unknown default: throw ModelConnectionError.message("Неизвестный формат изображения.")
                }
            }
        }
    }
}

struct CodexResponseAccumulator {
    var text = ""
    var calls: [Transcript.ToolCall] = []
    var completed = false
    var textChanged = false
    mutating func consume(_ line: String) throws {
        textChanged = false
        guard line.hasPrefix("data:"), let data = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "response.output_text.delta":
            text += event["delta"] as? String ?? ""
            textChanged = true
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any] { try collect(item) }
        case "response.completed":
            if let response = event["response"] as? [String: Any], let items = response["output"] as? [[String: Any]] {
                for item in items { try collect(item) }
                if text.isEmpty {
                    text = items.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined()
                    textChanged = !text.isEmpty
                }
            }
            completed = true
        case "error", "response.failed", "response.incomplete":
            throw ModelConnectionError.message("Codex не завершил ответ. Повторите запрос или проверьте доступ к модели.")
        default: break
        }
    }
    private mutating func collect(_ item: [String: Any]) throws {
        guard item["type"] as? String == "function_call", let id = item["call_id"] as? String,
              let name = item["name"] as? String, !calls.contains(where: { $0.id == id }) else { return }
        calls.append(.init(id: id, toolName: name, arguments: try GeneratedContent(json: item["arguments"] as? String ?? "{}")))
    }
}
