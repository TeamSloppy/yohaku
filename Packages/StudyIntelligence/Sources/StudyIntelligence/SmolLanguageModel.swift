import AnyLanguageModel
import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import StudyCore

/// ALM-compatible provider which owns the native task through cancellation and GPU completion.
/// The stock ALM MLX stream discards generateTask's handle; starting another run too early can
/// race the native compiler cache. Keep this bounded adapter for legacy SmolVLM checkpoints.
struct SmolLanguageModel: AnyLanguageModel.LanguageModel {
    typealias UnavailableReason = String
    let directory: URL
    let limits: LocalInferenceLimits
    var availability: Availability<String> { .available }
    static func waitUntilIdle() async { await SmolGenerationGate.shared.waitUntilIdle() }

    func respond<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
                                    includeSchemaInPrompt: Bool, options: GenerationOptions) async throws -> LanguageModelSession.Response<Content> {
        guard type == String.self else { throw StudyError.modelUnavailable("SmolVLM поддерживает текстовые ответы.") }
        var text = ""
        for try await update in streamResponse(within: session, to: prompt, generating: String.self, includeSchemaInPrompt: false, options: options) { text = update.content }
        let raw = GeneratedContent(text)
        return .init(content: try Content(raw), rawContent: raw, transcriptEntries: [])
    }

    func streamResponse<Content: Generable>(within session: LanguageModelSession, to prompt: Prompt, generating type: Content.Type,
                                           includeSchemaInPrompt: Bool, options: GenerationOptions) -> sending LanguageModelSession.ResponseStream<Content> {
        let stream = AsyncThrowingStream<LanguageModelSession.ResponseStream<Content>.Snapshot, Error> { continuation in
            let task = Task {
                var entered = false
                do {
                    guard type == String.self, session.tools.isEmpty else { throw StudyError.modelUnavailable("SmolVLM поддерживает текстовые ответы без инструментов.") }
                    try await SmolGenerationGate.shared.enter(); entered = true
                    try Task.checkCancellation()
                    try await generate(session: session, prompt: prompt.description, options: options) { text in
                        let raw = GeneratedContent(text)
                        let value = try Content(raw)
                        continuation.yield(.init(content: value.asPartiallyGenerated(), rawContent: raw))
                    }
                    await SmolGenerationGate.shared.leave(); entered = false
                    continuation.finish()
                } catch {
                    if entered { await SmolGenerationGate.shared.leave() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(stream: stream)
    }

    private func generate(session: LanguageModelSession, prompt: String, options: GenerationOptions,
                          output: @escaping @Sendable (String) throws -> Void) async throws {
        try await MLX.withError { error in
            MLX.Memory.cacheLimit = 32 * 1024 * 1024
            defer { MLX.Memory.clearCache() }
            let eos = try await LocalModelCompatibility.prepare(directory: directory, maximumInputTokens: limits.inputTokens)
            let config = MLXLMCommon.ModelConfiguration(directory: directory, extraEOSTokens: Set(eos))
            var context = try await VLMModelFactory.shared.load(configuration: config)
            try error.check(); try Task.checkCancellation()
            // This also handles checkpoints whose config.json has no eos_token_id.
            context.configuration.extraEOSTokens.formUnion(eos)
            let chat = try Self.messages(session: session, fallback: prompt)
            let input = try await context.processor.prepare(input: UserInput(chat: chat))
            try error.check(); try Task.checkCancellation()
            let parameters = GenerateParameters(maxTokens: min(options.maximumResponseTokens ?? limits.outputTokens, limits.outputTokens),
                                                maxKVSize: limits.cacheTokens, temperature: Float(options.temperature ?? 0.4), prefillStepSize: 256)
            let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
            try error.check()
            let (events, producer) = generateTask(promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration,
                                                  tokenizer: context.tokenizer, iterator: iterator)
            var answer = ""
            do {
                for await event in events {
                    try Task.checkCancellation(); try error.check()
                    if case .chunk(let text) = event { answer += text; try output(answer) }
                }
                if Task.isCancelled { producer.cancel() }
                await producer.value
                try Task.checkCancellation(); try error.check()
            } catch {
                producer.cancel()
                // Never release the model or permit another run while native code still uses it.
                await producer.value
                throw error
            }
        }
    }

    private static func messages(session: LanguageModelSession, fallback: String) throws -> [MLXLMCommon.Chat.Message] {
        var messages: [MLXLMCommon.Chat.Message] = []
        for entry in session.transcript {
            let role: MLXLMCommon.Chat.Message.Role
            let segments: [Transcript.Segment]
            switch entry {
            case .instructions(let value): role = .system; segments = value.segments
            case .prompt(let value): role = .user; segments = value.segments
            case .response(let value): role = .assistant; segments = value.segments
            case .toolCalls, .toolOutput: throw StudyError.modelUnavailable("SmolVLM не поддерживает этот инструментальный контекст.")
            }
            var text: [String] = [], images: [UserInput.Image] = []
            for segment in segments {
                switch segment {
                case .text(let value): text.append(value.content)
                case .structure(let value): text.append(value.content.jsonString)
                case .image(let value):
                    let image: CIImage?
                    switch value.source {
                    case .data(let data, _): image = CIImage(data: data, options: [.applyOrientationProperty: true])
                    case .url(let url):
                        guard url.isFileURL else { throw StudyError.modelUnavailable("Для локальной модели сначала сохраните изображение на устройстве.") }
                        image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
                    }
                    guard let image else { throw StudyError.modelUnavailable("Не удалось прочитать изображение.") }
                    images.append(.ciImage(image))
                }
            }
            messages.append(.init(role: role, content: text.joined(separator: "\n"), images: images))
        }
        if !messages.contains(where: { $0.role == .system }), let instructions = session.instructions?.description, !instructions.isEmpty {
            messages.insert(.system(instructions), at: 0)
        }
        if !messages.contains(where: { $0.role == .user }) { messages.append(.user(fallback)) }
        return messages
    }
}

private actor SmolGenerationGate {
    static let shared = SmolGenerationGate()
    private var active = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() throws {
        guard !active else { throw StudyError.modelUnavailable("Предыдущий локальный запрос ещё завершается. Повторите через секунду.") }
        active = true
    }
    func waitUntilIdle() async {
        guard active else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
        active = false
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}
