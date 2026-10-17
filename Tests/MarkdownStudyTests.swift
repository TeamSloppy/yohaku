import Foundation
import StudyCore
import Testing
@testable import StudyIntelligence
@testable import Yohaku

struct MarkdownStudyTests {
    private func snapshot(_ text: String = "猫はかわいい。", local: Bool = false) throws -> StudySourceSnapshot {
        var content = DocumentContent(kind: .markdown); content.markdown = text
        var config = ModelConfiguration(); config.provider = local ? .local : .network
        return try .init(vaultID: "vault", epoch: UUID(), path: "note.md", content: content, configuration: config)
    }
    private var card: SourceGeneratedFlashcard {
        .init(japanese: "猫", reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "Существительное", sourceID: "excerpt", quote: "猫はかわいい。")
    }
    @Test func frontmatterBoundsAndProviderDisclosure() throws {
        let source = try snapshot("\u{FEFF}---\r\nsecret: private\r\n---\r\n" + String(repeating: "猫", count: 4100))
        #expect(source.excerpt == String(repeating: "猫", count: 4000)); #expect(source.truncated)
        #expect(try snapshot(String(repeating: "猫", count: 700), local: true).excerpt.count == 600)
        for text in ["", "---\nsecret: private", "---\nsecret: private\n---"] {
            #expect(throws: Error.self) { try snapshot(text) }
        }
        var config = source.configuration; config.endpoint = "https://user:password@example.test/v1?token=hidden"
        var content = DocumentContent(kind: .markdown); content.markdown = "猫"
        let redacted = try StudySourceSnapshot(vaultID: "v", epoch: UUID(), path: "n.md", content: content, configuration: config)
        #expect(redacted.providerSummary == "https://example.test/v1 · ")
    }
    @Test(arguments: 0..<7) func sourceValidatorRejectsInvalidCandidates(variant: Int) throws {
        var invalid = card
        switch variant {
        case 0: invalid.quote = "犬はかわいい。"
        case 1: invalid.japanese = "犬"
        case 2: invalid.sourceID = "other"
        case 3: invalid.translation = " "
        case 4: invalid.note = String(repeating: "a", count: 801)
        case 5: invalid.reading = ""
        default: invalid.example = ""
        }
        #expect(throws: Error.self) { try MaterialGenerationService.validate([invalid], source: snapshot()) }
    }
    @Test func typedAndStringValidationAgreeAndRejectUnknownFieldsCountsAndDuplicates() throws {
        let source = try snapshot()
        let json = #"{"cards":[{"japanese":"猫","reading":"ねこ","translation":"кошка","example":"猫がいます。","note":"Существительное","sourceID":"excerpt","quote":"猫はかわいい。"}]}"#
        let typed = SourceGeneratedCards(cards: [card]).generatedContent.jsonString
        #expect(try MaterialGenerationService.parse(json, source: source) == MaterialGenerationService.parse(typed, source: source))
        #expect(throws: Error.self) { try MaterialGenerationService.parse(json.replacingOccurrences(of: "\"reading\":\"ねこ\"", with: "\"reading\":7"), source: source) }
        let parsed = try #require(MaterialGenerationService.parse(json, source: source).first)
        #expect([parsed.japanese, parsed.reading, parsed.translation, parsed.example, parsed.note, parsed.sourceID, parsed.quote] == [card.japanese, card.reading, card.translation, card.example, card.note, card.sourceID, card.quote])
        #expect(try MaterialGenerationService.parse(json, source: source) == MaterialGenerationService.validate([card], source: source))
        #expect(throws: Error.self) { try MaterialGenerationService.parse(json.replacingOccurrences(of: "\"sourceID\":", with: "\"extra\":1,\"sourceID\":"), source: source) }
        #expect(throws: Error.self) { try MaterialGenerationService.parse("prefix " + json, source: source) }
        #expect(throws: Error.self) { try MaterialGenerationService.validate([], source: source) }
        #expect(throws: Error.self) { try MaterialGenerationService.validate([card, card], source: source) }
        #expect(throws: Error.self) { try MaterialGenerationService.validate(Array(repeating: card, count: 6), source: source) }
        #expect(throws: Error.self) { try MaterialGenerationService.validate([card, card], source: snapshot(local: true)) }
    }
    @MainActor private func workspace() async throws -> (WorkspaceModel, StudySourceSnapshot) {
        let workspace = WorkspaceModel()
        var config = workspace.agent.configuration; config.provider = .network; config.remoteID = "fixture"
        workspace.agent.configuration = config
        try await workspace.openVault(URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), remember: false)
        _ = try await workspace.store!.create("note.md", kind: .markdown, text: "猫はかわいい。")
        await workspace.open("note.md")
        return (workspace, try await workspace.prepareMarkdownStudy(workspace.sessions["note.md"]!))
    }
    @MainActor private func finish(_ workspace: WorkspaceModel) async {
        while workspace.markdownStudyRunning { await Task.yield() }
    }
    @Test @MainActor func acceptPreservesQuoteAndPreviewRechecksSource() async throws {
        let (workspace, source) = try await workspace()
        workspace.generateMarkdownStudy(source) { _ in [card] }; await finish(workspace)
        #expect(await workspace.acceptMarkdownStudy(source, selected: [0]))
        #expect(workspace.flashcards.cards.first?.sourceExcerpt == card.quote)
        #expect(workspace.flashcards.cards.first?.sourcePath == "note.md")
        #expect(workspace.flashcards.cards.first?.example == card.example)
        workspace.sessions["note.md"]!.edit { $0.markdown += "変更" }
        #expect(!(await workspace.acceptMarkdownStudy(source, selected: [0])))
        #expect(workspace.flashcards.cards.count == 1)
    }
    @Test(arguments: 0..<5) @MainActor func lateResponseRejectsSourceChanges(variant: Int) async throws {
        let (workspace, source) = try await workspace()
        let gate = MarkdownGenerationGate()
        workspace.generateMarkdownStudy(source) { _ in await gate.wait() }
        while gate.continuation == nil { await Task.yield() }
        let store = workspace.store!
        switch variant {
        case 0: workspace.sessions["note.md"]!.edit { $0.markdown += "変更" }
        case 1:
            let loaded = try await store.load("note.md"); var content = loaded.content; content.markdown = "犬"
            _ = try await store.save("note.md", content: content, expectedRevision: loaded.revision)
        case 2: try FileManager.default.removeItem(at: workspace.root!.appendingPathComponent("note.md"))
        case 3: try FileManager.default.moveItem(at: workspace.root!.appendingPathComponent("note.md"), to: workspace.root!.appendingPathComponent("moved.md"))
        default: workspace.agent.configuration.remoteID = "changed"
        }
        gate.continuation?.resume(returning: [card]); await finish(workspace)
        #expect(workspace.markdownStudyCards.isEmpty); #expect(workspace.markdownStudyError != nil)
        #expect(workspace.flashcards.cards.isEmpty)
    }
    @Test @MainActor func cancelAndVaultRoundTripRejectLateResponse() async throws {
        for switchVault in [false, true] {
            let (workspace, source) = try await workspace(); let root = workspace.root!
            let gate = MarkdownGenerationGate()
            workspace.generateMarkdownStudy(source) { _ in await gate.wait() }
            while gate.continuation == nil { await Task.yield() }
            if switchVault {
                try await workspace.openVault(URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), remember: false)
                try await workspace.openVault(root, remember: false); await workspace.open("note.md")
            } else { workspace.cancelMarkdownStudy() }
            #expect(workspace.markdownStudyRunning)
            gate.continuation?.resume(returning: [card]); await finish(workspace)
            #expect(workspace.markdownStudyCards.isEmpty)
            #expect(!(await workspace.acceptMarkdownStudy(source, selected: [0])))
            #expect(workspace.flashcards.cards.isEmpty); #expect(workspace.markdownStudyError == nil)
        }
    }
    @Test @MainActor func memoryReleaseWaitsForOwnedGenerationCancellation() async throws {
        let agent = AgentSession(), gate = MarkdownGenerationGate()
        let request = Task { try await agent.runSourceGeneration { await gate.wait() } }
        while gate.continuation == nil { await Task.yield() }
        #expect(agent.running)
        var released = false
        let release = Task { await agent.releaseMemory(); released = true }
        await Task.yield(); #expect(!released); #expect(agent.running)
        gate.continuation?.resume(returning: [card])
        await release.value
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(released); #expect(!agent.running)
    }
    @Test @MainActor func saveFailureBlocksPreparation() async throws {
        let (workspace, _) = try await workspace(); let session = workspace.sessions["note.md"]!
        try FileManager.default.removeItem(at: workspace.root!.appendingPathComponent("note.md"))
        try FileManager.default.createDirectory(at: workspace.root!.appendingPathComponent("note.md"), withIntermediateDirectories: true)
        session.edit { $0.markdown += "変更" }
        await #expect(throws: Error.self) { try await workspace.prepareMarkdownStudy(session) }
        #expect(session.isDirty); #expect(session.error != nil)
    }
    @Test @MainActor func savedSourceConflictBlocksPreparation() async throws {
        let (workspace, _) = try await workspace(); let session = workspace.sessions["note.md"]!
        session.edit { $0.markdown += "変更" }; session.conflictPath = "conflict.md"
        await #expect(throws: Error.self) { try await workspace.prepareMarkdownStudy(session) }
        #expect(session.isDirty)
    }
}
@MainActor private final class MarkdownGenerationGate {
    var continuation: CheckedContinuation<[SourceGeneratedFlashcard], Never>?
    func wait() async -> [SourceGeneratedFlashcard] { await withCheckedContinuation { continuation = $0 } }
}
