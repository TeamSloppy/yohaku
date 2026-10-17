import Foundation
import StudyCore
import Testing
@testable import Yohaku
@testable import StudyIntelligence

struct StudyMaterialStoreTests {
    private func root() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func record() -> StudyMaterialRecord {
        .init(fields: StudyMaterialFields(Flashcard(japanese: "猫", reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "名詞")),
              source: .init(vaultID: "vault", documentID: UUID(), contentRevision: "1", path: "note.md", excerpt: "猫はかわいい。", quote: "猫はかわいい。"))
    }
    @Test @MainActor func rejectionAndAcceptanceSurviveRestartAndSuppressEquivalentRegeneration() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = record(); _ = try await store.save([original], ifCurrent: { true })
        #expect(await store.reject([original.id]))
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        var regenerated = original; regenerated.id = UUID(); regenerated.source.contentRevision = "2"
        #expect(try await reopened.save([regenerated], ifCurrent: { true }).isEmpty)
        #expect(reopened.records.first?.disposition == .rejected)
        regenerated.source.documentID = UUID()
        let pending = try #require(try await reopened.save([regenerated], ifCurrent: { true }).first)
        #expect(await reopened.accept(pending.id, cards: cards, validate: { _ in }))
        let again = StudyMaterialStore(writer: writer); await again.open(vaultRoot: root, cards: cards)
        #expect(again.records.last?.disposition == .accepted); #expect(cards.cards.count == 1)
        #expect(try await again.save([record()], ifCurrent: { true }).isEmpty)
    }
    @Test @MainActor func failedAcknowledgementReplaysOnceAndDeletedTargetRequiresCancellation() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = MaterialControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let material = record(); _ = try await store.save([material], ifCurrent: { true })
        await writer.failStateWrite(3)
        #expect(!(await store.accept(material.id, cards: cards, validate: { _ in })))
        #expect(cards.cards.count == 1); #expect(store.isBlocked)
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        #expect(!reopened.isBlocked); #expect(reopened.records.first?.disposition == .accepted); #expect(cards.cards.count == 1)
        var second = record(); second.fields.japanese = "犬"
        _ = try await reopened.save([second], ifCurrent: { true })
        await writer.failStateWrite(7)
        #expect(!(await reopened.accept(second.id, cards: cards, validate: { _ in })))
        let target = try #require(reopened.state.intents.first?.card.id)
        #expect(await cards.delete(id: target))
        let ambiguous = StudyMaterialStore(writer: writer); await ambiguous.open(vaultRoot: root, cards: cards)
        #expect(ambiguous.canCancelIntent); #expect(ambiguous.isBlocked)
        #expect(await ambiguous.cancelPendingAcceptance()); #expect(!ambiguous.isBlocked)
        #expect(ambiguous.records.last?.disposition == .pending); #expect(cards.cards.count == 1)
    }
    @Test @MainActor func unsupportedStateAndCASConflictBlockMaterialsButNotManualCards() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        _ = try await store.save([record()], ifCurrent: { true })
        let url = root.appendingPathComponent(".workspace/study-state.json"), external = Data(#"{"schemaVersion":2,"records":[],"intents":[]}"#.utf8)
        try external.write(to: url, options: .atomic)
        #expect(!(await store.reject(Set(store.records.map(\.id)))))
        #expect(store.isBlocked); #expect(try Data(contentsOf: url) == external)
        await store.recover(cards: cards); #expect(store.isBlocked)
        #expect(await cards.add(Flashcard(japanese: "手動", translation: "manual")))
    }
    @Test @MainActor func sameBatchNormalizationAndExistingLibraryAreDeduplicated() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = record(); var equivalent = original; equivalent.id = UUID(); equivalent.fields.reading = " ねこ "
        let saved = try await store.save([original, equivalent], ifCurrent: { true })
        #expect(saved.count == 1); #expect(Set(saved.map(\.id)).count == 1); #expect(store.records.count == 1)
        var anotherSource = equivalent; anotherSource.id = UUID(); anotherSource.source.documentID = UUID(); anotherSource.source.path = "other.md"
        let replaced = try await store.save([anotherSource], ifCurrent: { true })
        #expect(replaced.first?.id == saved.first?.id); #expect(store.records.count == 1)
        #expect(store.records.first?.source.path == "other.md")
        #expect(try await store.save([record()], existingCards: [original.makeCard()], ifCurrent: { true }).isEmpty)
        var different = original; different.id = UUID(); different.fields.example += "別"
        #expect(try await store.save([different], existingCards: [original.makeCard()], ifCurrent: { true }).count == 1)
        different.id = UUID(); different.fields.reading += "別"
        #expect(try await store.save([different], existingCards: [original.makeCard()], ifCurrent: { true }).count == 1)
    }
    @Test @MainActor func workspaceRefreshPreservesAmbiguousRecoveryAction() async throws {
        let writer = MaterialControlledWriter(), (workspace, source) = try await generatedWorkspace(writer: writer), root = workspace.root!
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.generateMarkdownStudy(source) { _ in [generated] }
        while workspace.markdownStudyRunning { await Task.yield() }
        let id = try #require(workspace.materials.records.first?.id)
        await writer.failStateWrite(3)
        #expect(!(await workspace.acceptStudyMaterials([id])))
        let target = try #require(workspace.materials.state.intents.first?.card.id)
        #expect(await workspace.flashcards.delete(id: target))
        let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
        #expect(reopened.materials.canCancelIntent)
        await reopened.refreshStudyMaterials(); #expect(reopened.materials.canCancelIntent)
        #expect(!(await reopened.materials.reject([id]))); #expect(reopened.materials.canCancelIntent)
        #expect(await reopened.materials.cancelPendingAcceptance()); #expect(!reopened.materials.isBlocked)
    }
    @Test @MainActor func supersessionDuringSourceValidationPreventsIntent() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer), gate = MaterialStoreGate()
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let material = record(); _ = try await store.save([material], ifCurrent: { true })
        let accepting = Task { await store.accept(material.id, cards: cards) { _ in await gate.wait() } }
        while gate.continuation == nil { await Task.yield() }
        store.markSuperseded([material.id]); let invalidation = Task { await store.supersede([material.id]) }
        gate.continuation?.resume()
        #expect(!(await accepting.value)); #expect(await invalidation.value); #expect(cards.cards.isEmpty)
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        await reopened.refreshSources { _ in .current }
        #expect(reopened.records.first?.sourceSuperseded == true); #expect(reopened.records.first?.freshness == .stale)
    }
    @MainActor private func generatedWorkspace(writer: any StudyFileWriting & StudyStateFileWriting = StudyFileWriter()) async throws -> (WorkspaceModel, StudySourceSnapshot) {
        let workspace = WorkspaceModel(writer: writer)
        var config = workspace.agent.configuration; config.provider = .network; config.remoteID = "fixture"; workspace.agent.configuration = config
        try await workspace.openVault(root(), remember: false)
        _ = try await workspace.store!.create("note.md", kind: .markdown, text: "猫はかわいい。")
        await workspace.open("note.md")
        return (workspace, try await workspace.prepareMarkdownStudy(workspace.sessions["note.md"]!))
    }
    private var generated: SourceGeneratedFlashcard { .init(japanese: "猫", reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "名詞", sourceID: "excerpt", quote: "猫はかわいい。") }
    @Test @MainActor func savedProposalAcceptsWithoutEditorOrProviderAndTracksSourceChanges() async throws {
        let (workspace, source) = try await generatedWorkspace(); let root = workspace.root!
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.generateMarkdownStudy(source) { _ in [generated] }
        while workspace.markdownStudyRunning { await Task.yield() }
        let id = try #require(workspace.materials.records.first?.id); workspace.cancelMarkdownStudy()
        let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
        await reopened.close("note.md"); reopened.agent.configuration.remoteID = "unavailable"
        #expect(await reopened.acceptStudyMaterials([id])); #expect(reopened.flashcards.cards.count == 1)
        let loaded = try await reopened.store!.load("note.md"); var content = loaded.content
        content.messages.append(.init(role: .user, text: "chat only"))
        _ = try await reopened.store!.save("note.md", content: content, expectedRevision: loaded.revision)
        await reopened.refreshStudyMaterials(); #expect(reopened.materials.records.first?.freshness == .current)
        content.markdown += "変更"
        let current = try await reopened.store!.load("note.md")
        _ = try await reopened.store!.save("note.md", content: content, expectedRevision: current.revision)
        await reopened.refreshStudyMaterials()
        #expect(reopened.materials.records.first?.freshness == .stale); #expect(reopened.materials.records.first?.disposition == .accepted)
    }
    @Test @MainActor func queuedAcceptanceRereadsSourceAfterCardFIFO() async throws {
        let writer = MaterialControlledWriter(), (workspace, source) = try await generatedWorkspace(writer: writer), root = workspace.root!
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.generateMarkdownStudy(source) { _ in [generated] }
        while workspace.markdownStudyRunning { await Task.yield() }
        let id = try #require(workspace.materials.records.first?.id)
        await writer.pauseNextCardWrite()
        let adding = Task { await workspace.flashcards.add(Flashcard(japanese: "手動", translation: "manual")) }
        await writer.waitUntilPaused()
        var started = false
        let accepting = Task { started = true; return await workspace.acceptStudyMaterials([id]) }
        while !started { await Task.yield() }
        let loaded = try await workspace.store!.load("note.md"); var changed = loaded.content; changed.markdown += "変更"
        _ = try await workspace.store!.save("note.md", content: changed, expectedRevision: loaded.revision)
        await writer.resume(); #expect(await adding.value); #expect(!(await accepting.value))
        #expect(workspace.materials.state.intents.isEmpty)
        #expect(workspace.flashcards.cards.map(\.japanese) == ["手動"])
    }
    @Test(arguments: [false, true]) @MainActor func pendingSourceMoveOrDeletionIsPersisted(deleted: Bool) async throws {
        let (workspace, source) = try await generatedWorkspace(), root = workspace.root!
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.generateMarkdownStudy(source) { _ in [generated] }
        while workspace.markdownStudyRunning { await Task.yield() }
        let id = try #require(workspace.materials.records.first?.id)
        if deleted { try FileManager.default.removeItem(at: root.appendingPathComponent("note.md")); await workspace.refreshStudyMaterials() }
        else { await workspace.move("note.md", to: "moved.md") }
        let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
        #expect(reopened.materials.records.first?.freshness == (deleted ? .missing : .current))
        #expect(reopened.materials.records.first?.source.path == (deleted ? "note.md" : "moved.md"))
        #expect(await reopened.acceptStudyMaterials([id]) == !deleted)
    }
    @Test @MainActor func crossScopeReusedIDIsSupersededDuringSave() async throws {
        let writer = MaterialControlledWriter(), (workspace, source) = try await generatedWorkspace(writer: writer), root = workspace.root!
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.generateMarkdownStudy(source) { _ in [generated] }
        while workspace.markdownStudyRunning { await Task.yield() }
        let id = try #require(workspace.materials.records.first?.id)
        _ = try await workspace.store!.create("other.md", kind: .markdown, text: "猫はかわいい。")
        await workspace.open("other.md")
        let other = try await workspace.prepareMarkdownStudy(workspace.sessions["other.md"]!)
        await writer.pauseNextStateWrite()
        workspace.generateMarkdownStudy(other) { _ in [generated] }; await writer.waitUntilPaused()
        workspace.invalidateStudyTranscription(); await writer.resume()
        while workspace.markdownStudyRunning { await Task.yield() }
        let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
        #expect(reopened.materials.records.count == 1); #expect(reopened.materials.records.first?.id == id)
        #expect(reopened.materials.records.first?.source.path == "other.md")
        #expect(reopened.materials.records.first?.sourceSuperseded == true)
        #expect(!(await reopened.acceptStudyMaterials([id])))
    }
    @Test @MainActor func inFlightTranscriptionEditPersistsStaleButClosingPreservesProposal() async throws {
        for edited in [false, true] {
            let writer = MaterialControlledWriter(), (workspace, source) = try await generatedWorkspace(writer: writer), root = workspace.root!
            await writer.pauseNextStateWrite()
            workspace.generateMarkdownStudy(source) { _ in [generated] }
            await writer.waitUntilPaused()
            if edited { workspace.invalidateStudyTranscription() } else { workspace.cancelMarkdownStudy() }
            await writer.resume()
            while workspace.markdownStudyRunning { await Task.yield() }
            let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
            let record = try #require(reopened.materials.records.first)
            #expect(record.freshness == (edited ? .stale : .current)); #expect((record.sourceSuperseded == true) == edited)
            #expect(await reopened.acceptStudyMaterials([record.id]) == !edited)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
@MainActor private final class MaterialStoreGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
}
private actor MaterialControlledWriter: StudyStateFileWriting, StudyFileWriting {
    let base = StudyFileWriter()
    var count = 0, failure: Int?
    var pause = false, pauseCards = false
    var pending: CheckedContinuation<Void, Never>?, observer: CheckedContinuation<Void, Never>?
    func failStateWrite(_ number: Int) { failure = number }
    func pauseNextStateWrite() { pause = true }
    func pauseNextCardWrite() { pauseCards = true }
    func waitUntilPaused() async { if pending == nil { await withCheckedContinuation { observer = $0 } } }
    func resume() { pending?.resume(); pending = nil }
    func load(_ url: URL) async throws -> StudyFileSnapshot { try await base.load(url) }
    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) async throws -> String {
        if pauseCards { pauseCards = false; await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil } }
        return try await base.write(cards, to: url, expectedRevision: expectedRevision)
    }
    func recover(_ url: URL) async throws -> StudyFileSnapshot { try await base.recover(url) }
    func writeImportedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?, intent: StudyAcceptanceIntent, dependency: StudyStateDependency) async throws -> String {
        let writer: any StudyFileWriting = base
        return try await writer.writeImportedCards(cards, to: url, expectedRevision: expectedRevision, intent: intent, dependency: dependency)
    }
    func loadState(_ url: URL) async throws -> StudyStateSnapshot { try await base.loadState(url) }
    func recoverState(_ url: URL) async throws -> StudyStateSnapshot { try await base.recoverState(url) }
    func writeState(_ state: StudyMaterialState, to url: URL, expectedRevision: String?) async throws -> String {
        count += 1
        if pause { pause = false; await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil } }
        if count == failure { throw CocoaError(.fileWriteNoPermission) }
        return try await base.writeState(state, to: url, expectedRevision: expectedRevision)
    }
}
