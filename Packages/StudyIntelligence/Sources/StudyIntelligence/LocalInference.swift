import AnyLanguageModel
import Foundation
import MLX
import os
import StudyCore

struct LocalInferenceLimits: Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let cacheTokens: Int
    let memoryBudget: UInt64
    let historyCharacters: Int
    let selectionCharacters: Int

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        let constrained = physicalMemory <= 4 * 1024 * 1024 * 1024
        inputTokens = constrained ? 1024 : 2048
        outputTokens = constrained ? 256 : 512
        cacheTokens = inputTokens + outputTokens + 256
        memoryBudget = min(physicalMemory / 2, constrained ? 1536 * 1024 * 1024 : 3 * 1024 * 1024 * 1024)
        historyCharacters = constrained ? 512 : 1500
        selectionCharacters = constrained ? 600 : 2000
    }

    func validate(weightBytes: UInt64, availableMemory: UInt64? = nil) throws {
        guard weightBytes > 0, weightBytes < UInt64.max / 4 else {
            throw StudyError.modelUnavailable("Не найдены корректные веса safetensors. Повторите загрузку модели.")
        }
        // Conservative admission estimate, not a measured peak and not a jetsam guarantee.
        let estimate = weightBytes * 2 + 512 * 1024 * 1024
        let available = availableMemory.map { $0 > 128 * 1024 * 1024 ? $0 - 128 * 1024 * 1024 : 0 } ?? memoryBudget
        guard estimate <= min(memoryBudget, available) else {
            throw StudyError.modelUnavailable("Недостаточно свободной памяти для этой модели. Откройте подбор по характеристикам устройства, выберите более лёгкую модель или закройте тяжёлые приложения.")
        }
    }
}

enum LocalInference {
    struct Update: Sendable { let text: String; let peakBytes: Int }
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    /// Preflight prevents invalid graphs; MLX's supported task-local scope forwards runtime errors.
    /// Metal bootstrap assertions cannot be caught, so the application blocks simulator inference.
    static func stream(session: LanguageModelSession, prompt: String, images: [Transcript.ImageSegment], options: GenerationOptions, stopSequences: [String] = []) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await MLX.withError { error in
                        MLX.Memory.peakMemory = 0
                        let stream = session.streamResponse(to: prompt, images: images, options: options)
                        for try await snapshot in stream {
                            try Task.checkCancellation(); try error.check()
                            let end = stopSequences.compactMap { snapshot.content.range(of: $0)?.lowerBound }.min()
                            let text = end.map { String(snapshot.content[..<$0]) } ?? snapshot.content
                            continuation.yield(Update(text: text, peakBytes: MLX.Memory.peakMemory))
                            // Native providers stop by EOS. Never cut off their GPU task merely
                            // because its textual end marker appeared in a snapshot.
                        }
                        try error.check()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static var availableMemory: UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }
}
