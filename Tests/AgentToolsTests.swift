import AnyLanguageModel
import Foundation
import CoreImage
import MLX
import MLXLMCommon
import Tokenizers
import StudyCore
import Testing
@testable import StudyIntelligence

@MainActor struct AgentToolsTests {
    @Test func nativeToolsProposeWithoutWritingAndRespectLoopLimit() async throws {
        let store = VaultStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try await store.prepare()
        let loaded = try await store.create("Japanese.md", kind: .markdown, text: "original 日本語")
        let document = DocumentSession(path: "Japanese.md", loaded: loaded, store: store)
        var proposals: [ChangeProposal] = []
        let runtime = NotesToolRuntime(document: document, propose: { proposals.append($0) })
        // No network request is issued: the real delegate receives native framework tool calls.
        let session = LanguageModelSession(model: OpenAILanguageModel(apiKey: "test", model: "test"))
        let read = try call(operation: "read", revision: "", text: "")
        _ = await runtime.toolCallDecision(for: read, in: session)
        let propose = try call(operation: "replace_markdown", revision: loaded.content.contentRevision, text: "new 日本語")
        _ = await runtime.toolCallDecision(for: propose, in: session)
        #expect(proposals.count == 1)
        #expect(try await store.load("Japanese.md").content.markdown == "original 日本語")
        try await document.accept(#require(proposals.first))
        #expect(document.content.markdown == "new 日本語")
        _ = await runtime.toolCallDecision(for: read, in: session)
        let limited = await runtime.toolCallDecision(for: read, in: session)
        if case .stop = limited {} else { Issue.record("Repeated tool calls must stop the loop") }
    }
    private func call(operation: String, revision: String, text: String) throws -> Transcript.ToolCall {
        let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "path": "Japanese.md", "text": text, "revision": revision, "pageID": ""])
        let args = try GeneratedContent(json: String(decoding: data, as: UTF8.self))
        return .init(id: UUID().uuidString, toolName: "notes", arguments: args)
    }
}

@MainActor @Suite(.serialized) struct SmolVisionTests {
    private let modelJSON = Data(#"{"model_type":"idefics3","vision_config":{"image_size":512,"patch_size":16,"hidden_size":768},"scale_factor":4,"image_token_id":49190}"#.utf8)
    private let processorJSON = Data(#"{"image_mean":[0.5,0.5,0.5],"image_std":[0.5,0.5,0.5]}"#.utf8)

    @Test func legacySmolGeometryAndTokenExpansionAreConsistent() throws {
        let plan = try SmolVisionPlan(configuration: modelJSON)
        #expect(plan.patchCount == 1024)
        #expect(plan.imageTokenCount == 64)
        try plan.validatePositionEmbedding(shape: [1024, 768])
        #expect(throws: StudyError.self) { try plan.validatePositionEmbedding(shape: [576, 768]) }
        let quantizedJSON = Data(String(decoding: modelJSON, as: UTF8.self).dropLast().appending(",\"quantization\":{\"bits\":4,\"group_size\":64}}" ).utf8)
        let quantized = try SmolVisionPlan(configuration: quantizedJSON)
        try quantized.validatePositionEmbedding(shape: [1024, 96], dtype: "U32", scaleShape: [1024, 12])
        #expect(throws: StudyError.self) { try quantized.validatePositionEmbedding(shape: [576, 96], dtype: "U32", scaleShape: [576, 12]) }
        let processor = try SmolVisionProcessor(plan: plan, configuration: processorJSON, tokenizer: VisionTestTokenizer(), maximumInputTokens: 1024)
        let tokens = try processor.expandedImageTokens([7, 8, 49190, 9], hasImage: true)
        #expect(Array(tokens.prefix(4)) == [7, 8, 49189, 49152])
        #expect(Array(tokens.suffix(2)) == [49189, 9])
        #expect(tokens.filter { $0 == 49190 }.count == 64)
        #expect(throws: StudyError.self) { try processor.expandedImageTokens([49153], hasImage: true) }
        #expect(throws: StudyError.self) { try processor.expandedImageTokens([49190, 49190], hasImage: true) }
    }

    @Test func processorPadsOneFrameAndRejectsOversizedContext() async throws {
        let plan = try SmolVisionPlan(configuration: modelJSON)
        let processor = try SmolVisionProcessor(plan: plan, configuration: processorJSON, tokenizer: VisionTestTokenizer(), maximumInputTokens: 1024)
        let image = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 100, y: 70, width: 1200, height: 200))
        let normalized = try processor.normalizedImage(image)
        #expect(normalized.extent == CGRect(x: 0, y: 0, width: 512, height: 512))
        // Simulator Metal does not expose the GPU architecture required by this MLX release.
        // Real MLX tensor evaluation is covered by Validation/SmolProbe on Apple Silicon.
        let ci = CIContext(options: [.useSoftwareRenderer: true])
        var center = [Float](repeating: 0, count: 4)
        center.withUnsafeMutableBytes { ci.render(normalized, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 256, y: 256, width: 1, height: 1), format: .RGBAf, colorSpace: nil) }
        #expect(center[2] > 0.9 && center[0] < -0.9)
        let tooLong = try SmolVisionProcessor(plan: plan, configuration: processorJSON, tokenizer: VisionTestTokenizer(), maximumInputTokens: 10)
        await #expect(throws: StudyError.self) { try await tooLong.prepare(input: UserInput(chat: [.user("Read", images: [.ciImage(image)])])) }
        await #expect(throws: StudyError.self) { try await processor.prepare(input: UserInput(chat: [.user("Read", images: [.ciImage(image), .ciImage(image)])])) }
    }

    @Test func preflightRejectsBadConfigWeightsAndTokenizer() throws {
        let plan = try SmolVisionPlan(configuration: modelJSON)
        let bad = Data(String(decoding: modelJSON, as: UTF8.self).replacingOccurrences(of: "512", with: "510").utf8)
        #expect(throws: StudyError.self) { try SmolVisionPlan(configuration: bad) }
        #expect(throws: StudyError.self) {
            try SmolVisionProcessor(plan: plan, configuration: processorJSON, tokenizer: VisionTestTokenizer(imageID: 49153), maximumInputTokens: 1024)
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var header = try JSONSerialization.data(withJSONObject: ["model.vision_model.embeddings.position_embedding.weight": ["shape": [576, 768]]])
        var count = UInt64(header.count).littleEndian
        header = withUnsafeBytes(of: &count) { Data($0) } + header
        try header.write(to: folder.appendingPathComponent("model.safetensors"))
        #expect(throws: StudyError.self) { try plan.validateWeights(in: folder) }
    }

    @Test func fourGBBudgetAdmitsSmallModelAndRejectsMemoryPressure() throws {
        let limits = LocalInferenceLimits(physicalMemory: 4 * 1024 * 1024 * 1024)
        #expect(limits.inputTokens == 1024 && limits.outputTokens == 256)
        try limits.validate(weightBytes: 145_470_213, availableMemory: 1500 * 1024 * 1024)
        #expect(throws: StudyError.self) { try limits.validate(weightBytes: 145_470_213, availableMemory: 300 * 1024 * 1024) }
        #expect(throws: StudyError.self) { try limits.validate(weightBytes: 2_000_000_000) }
    }

}

/// Deterministic token IDs for processor contract tests. Real tokenizer/weights are exercised by Validation/SmolProbe.
private struct VisionTestTokenizer: Tokenizer {
    var imageID = 49190
    func tokenize(text: String) -> [String] { [text] }
    func encode(text: String) -> [Int] { [7, imageID, 9] }
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { encode(text: text) }
    func decode(tokens: [Int], skipSpecialTokens: Bool) -> String { "fixture" }
    func convertTokenToId(_ token: String) -> Int? { token == "<image>" ? imageID : token == "<fake_token_around_image>" ? 49189 : token == "<global-img>" ? 49152 : nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var bosTokenId: Int? { nil }
    var eosToken: String? { nil }; var eosTokenId: Int? { nil }
    var unknownToken: String? { nil }; var unknownTokenId: Int? { nil }
    func applyChatTemplate(messages: [Tokenizers.Message]) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], tools: [ToolSpec]?) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], tools: [ToolSpec]?, additionalContext: [String: any Sendable]?) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: ChatTemplateArgument) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: String) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?, tools: [ToolSpec]?) throws -> [Int] { encode(text: "") }
    func applyChatTemplate(messages: [Tokenizers.Message], chatTemplate: ChatTemplateArgument?, addGenerationPrompt: Bool, truncation: Bool, maxLength: Int?, tools: [ToolSpec]?, additionalContext: [String: any Sendable]?) throws -> [Int] { encode(text: "") }
}

@MainActor struct HuggingFaceCatalogTests {
    private var iPad2018: DeviceModelProfile {
        .init(identifier: "iPad8,1", name: "iPad Pro 2018", systemVersion: "26.5", physicalMemory: 4 * 1024 * 1024 * 1024,
              availableMemory: 1600 * 1024 * 1024, freeStorage: 8 * 1024 * 1024 * 1024, gpuName: "Apple A12X GPU")
    }
    private func inspected(id: String = "someone/new-model", bytes: UInt64? = 180_000_000, mlx: Bool = true, type: String = "qwen2") throws -> HFInspection {
        let model = HFModel(id: id, task: "text-generation", tags: mlx ? ["mlx"] : [])
        let repo = HFRepository(sha: "abc123", files: [.init(name: "config.json", size: 1000), .init(name: "model.safetensors", size: bytes)])
        return try HFInspection(model: model, repository: repo, configuration: JSONSerialization.data(withJSONObject: ["model_type": type]))
    }
    @Test func recommendationUsesMetadataNotCuratedModelNames() throws {
        let arbitraryModel = try inspected()
        #expect(ModelDeviceAssessment.evaluate(arbitraryModel, device: iPad2018).status == .candidate)
        #expect(ModelDeviceAssessment.evaluate(try inspected(bytes: 3_000_000_000), device: iPad2018).status == .tooLarge)
        #expect(ModelDeviceAssessment.evaluate(try inspected(mlx: false), device: iPad2018).status == .unsupported)
        #expect(ModelDeviceAssessment.evaluate(try inspected(type: "future-architecture"), device: iPad2018).status == .unsupported)
        #expect(ModelDeviceAssessment.evaluate(try inspected(bytes: nil), device: iPad2018).status == .unknown)
        #expect(ModelDeviceAssessment.evaluate(arbitraryModel, device: iPad2018, requiresVision: true).status == .unsupported)
    }
    @Test func searchEscapesInputAndAllCatalogHasNoSizeOrAuthorRestriction() throws {
        let query = "new model & author=someone"
        let all = HuggingFaceHub.searchURL(query: query, mlxOnly: false, task: nil)
        let params = try #require(URLComponents(url: all, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(params.first(where: { $0.name == "search" })?.value == query)
        #expect(!params.contains(where: { ["author", "filter", "num_parameters"].contains($0.name) }))
        let recommended = HuggingFaceHub.searchURL(query: "", mlxOnly: true, task: "image-text-to-text", maximumParameters: 1_000_000_000)
        #expect(URLComponents(url: recommended, resolvingAgainstBaseURL: false)?.queryItems?.contains(.init(name: "num_parameters", value: "min:0,max:1000000000")) == true)
    }
    @Test func credentialsAndPaginationStayOnTrustedOrigin() throws {
        let url = URL(string: "https://huggingface.co/api/models")!
        let request = try HuggingFaceHub.authorizedRequest(url, token: "hf_fixture")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer hf_fixture")
        #expect(throws: StudyError.self) { try HuggingFaceHub.authorizedRequest(URL(string: "https://example.com/models")!, token: "hf_fixture") }
        var redirect = request; redirect.url = URL(string: "https://cdn.example.com/signed-weights")
        #expect(HuggingFaceHub.redirectedRequest(redirect)?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(HuggingFaceHub.nextPage(from: "<https://example.com/api/models>; rel=\"next\"") == nil)
        #expect(HuggingFaceHub.nextPage(from: "<https://huggingface.co/api/models?cursor=next>; rel=\"next\"")?.host == "huggingface.co")
        #expect(ModelCatalog.normalizedID("https://huggingface.co/author/model") == "author/model")
        #expect(ModelCatalog.normalizedID("https://huggingface.co.evil.test/author/model") == nil)
        #expect(ModelCatalog.validID("gpt2"))
    }
    @Test func oldManifestResumesAndMixedWeightVariantsAreNotDownloadedTogether() throws {
        let legacy = Data(#"{"sha":"abc123","siblings":[{"rfilename":"config.json","size":100},{"rfilename":"model.safetensors","size":150000000}]}"#.utf8)
        let repo = try JSONDecoder().decode(HFRepository.self, from: legacy)
        try repo.validateLayout()
        #expect(repo.weightBytes == 150_000_000)
        let mixed = HFRepository(sha: "abc123", files: [.init(name: "config.json", size: 100), .init(name: "q4.safetensors", size: 100), .init(name: "q8.safetensors", size: 200)])
        #expect(throws: HFHubError.self) { try mixed.validateLayout() }
        #expect(throws: StudyError.self) { try HuggingFaceHub.fileURL(id: "author/model", revision: "main", name: "../escape") }
    }
    @Test func liveWireShapesAndErrorsDecodeThroughHTTPClient() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HubFixtureProtocol.self]
        let hub = HuggingFaceHub(session: URLSession(configuration: configuration), token: { "hf_fixture" })
        let page = try await hub.search(query: "custom", mlxOnly: false, task: nil)
        #expect(page.models.first?.id == "someone/new-model")
        #expect(page.models.first?.gated == true)
        #expect(page.nextPage != nil)
        let detail = try await hub.inspect("someone/new-model")
        #expect(detail.repository.weightBytes == 150_000_000)
        #expect(ModelDeviceAssessment.evaluate(detail, device: iPad2018).status == .candidate)
        await #expect(throws: HFHubError.self) { try await hub.inspect("private/denied") }
    }
}

private final class HubFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "huggingface.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let code: Int, body: String
        if url.path.contains("private/denied") { code = 403; body = "{}" }
        else if request.value(forHTTPHeaderField: "Authorization") != "Bearer hf_fixture" { code = 401; body = "{}" }
        else if url.path == "/api/models" {
            code = 200; body = #"[{"id":"someone/new-model","pipeline_tag":"text-generation","tags":["mlx"],"downloads":123,"gated":"manual"}]"#
        } else if url.path.hasSuffix("config.json") { code = 200; body = #"{"model_type":"qwen2","quantization":{"bits":4}}"# }
        else {
            code = 200; body = #"{"id":"someone/new-model","sha":"abc123","tags":["mlx"],"pipeline_tag":"text-generation","gated":false,"siblings":[{"rfilename":"config.json","size":100},{"rfilename":"model.safetensors","lfs":{"size":150000000}}]}"#
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Link": "<https://huggingface.co/api/models?cursor=next>; rel=\"next\""])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
