import AnyLanguageModel
import AppKit
import Foundation
import MLX
@testable import StudyIntelligence

/// A real-weight probe. It never calls a remote model and only uses synthetic images.
@main struct SmolProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("Probe failed: \(error)\n".utf8)); exit(1) }
    }
    @MainActor static func run() async throws {
        guard CommandLine.arguments.count == 2 else { print("Usage: SmolProbe /absolute/model/directory"); return }
        if CommandLine.arguments[1] == "--catalog" { try await catalog(); return }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try await LocalModelCompatibility.prepare(directory: directory, maximumInputTokens: 1024)
        let plan = try SmolVisionPlan(configuration: Data(contentsOf: directory.appendingPathComponent("config.json")))
        print("vision: \(plan.imageSize)x\(plan.imageSize), patches=\(plan.patchCount), tokens=\(plan.imageTokenCount)")
        let model = SmolLanguageModel(directory: directory, limits: .init(physicalMemory: 4 * 1024 * 1024 * 1024))
        for (name, color) in [("red", NSColor.red), ("blue", NSColor.blue)] {
            let image = NSImage(size: NSSize(width: 512, height: 512))
            image.lockFocus()
            color.setFill(); NSRect(x: 0, y: 0, width: 512, height: 512).fill()
            image.unlockFocus()
            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let session = LanguageModelSession(model: model)
            let start = ContinuousClock.now
            var answer = "", peak = 0
            for try await update in LocalInference.stream(session: session, prompt: "What is the main color in this image?", images: [.init(data: png, mimeType: "image/png")], options: .init(temperature: 0, maximumResponseTokens: 32), stopSequences: ["<end_of_utterance>"]) {
                answer = update.text; peak = update.peakBytes
            }
            guard !answer.isEmpty else { throw CocoaError(.coderInvalidValue) }
            print("\(name): answer=\(answer) peakMLXMiB=\(peak / 1048576) duration=\(start.duration(to: .now))")
            guard answer.lowercased().contains(name) else { throw CocoaError(.coderInvalidValue) }
        }
        let (ready, signal) = AsyncStream<Void>.makeStream()
        let worker = Task {
            do {
                let session = LanguageModelSession(model: model)
                for try await update in LocalInference.stream(session: session, prompt: "Write fifty detailed paragraphs about studying languages.", images: [], options: .init(temperature: 0, maximumResponseTokens: 256)) {
                    if !update.text.isEmpty { signal.yield(()); signal.finish() }
                }
            } catch is CancellationError {} catch { print("cancel probe error: \(error)") }
            signal.finish()
        }
        for await _ in ready { break }
        let cancelStart = ContinuousClock.now
        worker.cancel(); await worker.value
        await SmolLanguageModel.waitUntilIdle()
        print("cancellationJoined=\(cancelStart.duration(to: .now))")
        let finalSession = LanguageModelSession(model: model)
        var finalText = ""
        for try await update in LocalInference.stream(session: finalSession, prompt: "Say hello.", images: [], options: .init(temperature: 0, maximumResponseTokens: 16)) { finalText = update.text }
        guard !finalText.isEmpty else { throw CocoaError(.coderInvalidValue) }
        print("afterCancellation=\(finalText)")
        print("unloadedMLXMiB=\(MLX.Memory.activeMemory / 1048576)")
        do {
            try await checkErrorScope()
            throw CocoaError(.coderInvalidValue)
        } catch let error as MLXError { print("nativeErrorScope=\(error)") }
    }
    nonisolated static func checkErrorScope() async throws {
        try await MLX.withError {
            let child = Task { _ = MLXArray([1, 2]) + MLXArray([1, 2, 3]) }
            await child.value
        }
    }
    @MainActor static func catalog() async throws {
        let profile = DeviceModelProfile(identifier: "iPad8,1", name: "iPad Pro 2018 · validation profile", systemVersion: "26",
                                         physicalMemory: 4 * 1024 * 1024 * 1024, availableMemory: nil, freeStorage: 20 * 1024 * 1024 * 1024, gpuName: "A12X")
        let hub = HuggingFaceHub(token: { "" })
        let page = try await hub.search(query: "", mlxOnly: true, task: "image-text-to-text", maximumParameters: 1_000_000_000)
        print("Live HF search: \(page.models.count) results; nextPage=\(page.nextPage != nil)")
        for model in page.models.prefix(12) {
            do {
                let info = try await hub.inspect(model.id)
                let result = ModelDeviceAssessment.evaluate(info, device: profile, requiresVision: true)
                print("\(model.id) | \(result.status) | weights=\(info.repository.weightBytes ?? 0) | estimatedRAM=\(result.estimatedMemory ?? 0) | \(info.modelType ?? "unknown")")
            } catch { print("\(model.id) | metadata error: \(error.localizedDescription)") }
        }
    }
}
