import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import AnyLanguageModel

/// Sloppy inference v1 wire contract. Notes tools execute in Yohaku with user approval.
struct SloppyInferenceRequest: Codable, Sendable {
    var model: String
    var transcript: Transcript
    var tools: [SloppyInferenceToolDefinition]
    var options: GenerationOptions
    var reasoningEffort: String?
    var stream: Bool?

    init(model: String, transcript: Transcript, tools: [SloppyInferenceToolDefinition], options: GenerationOptions, reasoningEffort: String? = nil, stream: Bool = false) {
        self.model = model
        self.transcript = transcript
        self.tools = tools
        self.options = options
        self.reasoningEffort = reasoningEffort
        self.stream = stream
    }
}

struct SloppyInferenceToolDefinition: Codable, Sendable {
    var name: String
    var description: String
    var parameters: GenerationSchema

    init(tool: some Tool) {
        self.name = tool.name
        self.description = tool.description
        self.parameters = tool.parameters
    }
}

struct SloppyInferenceResponse: Codable, Sendable {
    var text: String
    var toolCalls: [Transcript.ToolCall]

    init(text: String, toolCalls: [Transcript.ToolCall]) {
        self.text = text
        self.toolCalls = toolCalls
    }
}

enum SloppyRemoteError: Error, LocalizedError {
    case invalidURL
    case http(Int)
    case unknownModel
    case toolUnavailable(String)
    case toolLoopLimit

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Укажите адрес сервера Sloppy с http:// или https://."
        case .http(let status): "Сервер Sloppy вернул HTTP \(status). Проверьте адрес, токен и версию сервера."
        case .unknownModel: "The requested model is not available for remote inference on this Sloppy server."
        case .toolUnavailable(let name): "Tool \(name) is not available on the requesting server."
        case .toolLoopLimit: "Sloppy remote inference exceeded the tool round limit."
        }
    }
}

enum SloppyRemoteEndpoint {
    static func url(base: String, path: String) throws -> URL {
        guard var url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw SloppyRemoteError.invalidURL }
        if url.lastPathComponent == "v1" { url.deleteLastPathComponent() }
        return url.appendingPathComponent("v1").appendingPathComponent(path)
    }
}

struct NetworkLanguageModel: LanguageModel {
    typealias UnavailableReason = Never
    let baseURL: String
    let accessToken: String
    let model: String
    let httpSession: URLSession
    private let codex: CodexAuthorization?

    init(baseURL: String, accessToken: String, model: String, session: URLSession = .shared, codex: CodexAuthorization? = nil) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.model = model
        self.httpSession = session
        self.codex = codex
    }

    func respond<Content: Generable>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> {
        try await generate(within: session, generating: type, includeSchemaInPrompt: includeSchemaInPrompt, options: options)
    }

    private func generate<Content: Generable>(
        within session: LanguageModelSession, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> LanguageModelSession.Response<Content> {
        var transcript = Array(session.transcript)
        var entries: [Transcript.Entry] = []
        let definitions = session.tools.map { SloppyInferenceToolDefinition(tool: $0) }
        if type != String.self, includeSchemaInPrompt {
            let schema = String(decoding: try JSONEncoder().encode(type.generationSchema), as: UTF8.self)
            transcript.append(.instructions(.init(
                segments: [.text(.init(content: "Return JSON matching this schema: \(schema)"))],
                toolDefinitions: []
            )))
        }
        for _ in 0..<64 {
            try Task.checkCancellation()
            let payload = SloppyInferenceRequest(model: model, transcript: Transcript(entries: transcript), tools: definitions, options: options, stream: onText != nil)
            let result: SloppyInferenceResponse
            if let codex {
                result = try await CodexResponsesTransport.round(payload, auth: codex, session: httpSession, onText: onText)
            } else {
                var request = URLRequest(url: try SloppyRemoteEndpoint.url(base: baseURL, path: "providers/inference"))
                request.httpMethod = "POST"
                request.timeoutInterval = 300
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !accessToken.isEmpty { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
                request.httpBody = try JSONEncoder().encode(payload)
                if let onText { result = try await streamingRequest(request, onText: onText) }
                else {
                    let (data, response) = try await httpSession.data(for: request)
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
                    result = try JSONDecoder().decode(SloppyInferenceResponse.self, from: data)
                }
            }
            if result.toolCalls.isEmpty {
                let raw = type == String.self ? GeneratedContent(result.text) : try GeneratedContent(json: result.text)
                return .init(content: try type.init(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
            }
            let calls = Transcript.Entry.toolCalls(.init(result.toolCalls))
            entries.append(calls)
            transcript.append(calls)
            await session.toolExecutionDelegate?.didGenerateToolCalls(result.toolCalls, in: session)
            for call in result.toolCalls {
                let decision = await session.toolExecutionDelegate?.toolCallDecision(for: call, in: session) ?? .execute
                let segments: [Transcript.Segment]
                switch decision {
                case .stop:
                    let raw = type == String.self ? GeneratedContent("") : try GeneratedContent(json: "{}")
                    return .init(content: try type.init(raw), rawContent: raw, transcriptEntries: ArraySlice(entries))
                case .provideOutput(let output): segments = output
                case .execute:
                    guard let tool = session.tools.first(where: { $0.name == call.toolName }) else {
                        throw SloppyRemoteError.toolUnavailable(call.toolName)
                    }
                    do { segments = try await execute(tool, arguments: call.arguments) }
                    catch {
                        await session.toolExecutionDelegate?.didFailToolCall(call, error: error, in: session)
                        throw error
                    }
                }
                let output = Transcript.ToolOutput(id: call.id, toolName: call.toolName, segments: segments)
                entries.append(.toolOutput(output))
                transcript.append(.toolOutput(output))
                await session.toolExecutionDelegate?.didExecuteToolCall(call, output: output, in: session)
            }
        }
        throw SloppyRemoteError.toolLoopLimit
    }

    func streamResponse<Content: Generable>(
        within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
        includeSchemaInPrompt: Bool, options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, any Error> { continuation in
            let task = Task<Void, Never> {
                do {
                    let onText: @Sendable (String) -> Void = { text in
                        if let snapshot = partialSnapshot(text, generating: type) {
                            continuation.yield(snapshot)
                        }
                    }
                    let response = try await generate(within: session, generating: type,
                                                      includeSchemaInPrompt: includeSchemaInPrompt,
                                                      options: options, onText: onText)
                    continuation.yield(.init(content: response.content.asPartiallyGenerated(), rawContent: response.rawContent))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return LanguageModelSession.ResponseStream(stream: stream)
    }

    private func partialSnapshot<Content: Generable>(_ text: String, generating type: Content.Type) -> LanguageModelSession.ResponseStream<Content>.Snapshot? {
        do {
            let raw: GeneratedContent
            if type == String.self { raw = GeneratedContent(text) }
            else { raw = try GeneratedContent(json: text) }
            let content = try Content.PartiallyGenerated(raw)
            return .init(content: content, rawContent: raw)
        } catch { return nil }
    }

    private func streamingRequest(_ request: URLRequest, onText: @Sendable (String) -> Void) async throws -> SloppyInferenceResponse {
        let (bytes, response) = try await httpSession.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
        var event = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.hasPrefix("event:") {
                event = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                guard event != "error" else { throw SloppyRemoteError.http(502) }
                let data = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                let snapshot = try JSONDecoder().decode(SloppyInferenceResponse.self, from: data)
                if event == "complete" { return snapshot }
                if event == "snapshot" { onText(snapshot.text) }
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private func execute<T: Tool>(_ tool: T, arguments: GeneratedContent) async throws -> [Transcript.Segment] {
        let output = try await tool.call(arguments: T.Arguments(arguments))
        if let structured = output as? any ConvertibleToGeneratedContent {
            return [.structure(.init(source: tool.name, content: structured.generatedContent))]
        }
        return [.text(.init(content: output.promptRepresentation.description))]
    }
}
