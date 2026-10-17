import Foundation
import StudyCore
import Testing
@testable import Yohaku

struct StudyMaterialPersistenceTests {
    private func root() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func stateURL(_ root: URL) -> URL { root.appendingPathComponent(".workspace/study-state.json") }
    private func cardsURL(_ root: URL) -> URL { root.appendingPathComponent(".workspace/flashcards.json") }
    private func material(_ word: String = "猫") -> StudyMaterialRecord {
        .init(fields: StudyMaterialFields(Flashcard(japanese: word, reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "名詞")),
              source: .init(vaultID: "vault", documentID: UUID(), contentRevision: "source", path: "note.md", excerpt: "猫はかわいい。", quote: "猫はかわいい。"))
    }
    private func persist(_ intent: StudyAcceptanceIntent, writer: StudyFileWriter, root: URL) async throws -> StudyStateDependency {
        let url = stateURL(root), loaded = try await writer.loadState(url)
        var state = loaded.state; state.intents.append(intent)
        return try await StudyStateDependency(url: url, revision: writer.writeState(state, to: url, expectedRevision: loaded.revision))
    }

    @Test func plainRecordsRoundTripAndStructuredNormalization() throws {
        var record = material(); record.disposition = .rejected; record.freshness = .stale; record.sourceSuperseded = true
        let state = StudyMaterialState(records: [record])
        #expect(try StudyMaterialState.decode(JSONEncoder().encode(state)) == state)
        var equivalent = record.makeCard(); equivalent.japanese = "  猫\n"; equivalent.translation = " КОШКА  "
        #expect(StudyMaterialFields(equivalent).fingerprint == record.fields.fingerprint)
        equivalent.reading = "different"
        #expect(StudyMaterialFields(equivalent).fingerprint != record.fields.fingerprint)
        var changed = record.source; changed.path = "moved.md"; changed.contentRevision = "new"
        #expect(changed.sameScope(as: record.source))
        changed.pageID = UUID(); #expect(!changed.sameScope(as: record.source))
    }
    @Test func absentStateIsEmptyButMalformedAndNewerAreNot() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), url = stateURL(root)
        #expect(try await writer.loadState(url).state == StudyMaterialState())
        _ = try await writer.writeState(.init(), to: url, expectedRevision: nil)
        for data in [Data("{}".utf8), Data("bad".utf8), Data(#"{"schemaVersion":2,"records":[],"intents":[]}"#.utf8)] {
            try data.write(to: url, options: .atomic)
            await #expect(throws: Error.self) { try await writer.loadState(url) }
            await #expect(throws: Error.self) { try await writer.recoverState(url) }
            #expect(try Data(contentsOf: url) == data)
        }
    }
    @Test func stateCASPreservesBothVersionsAndRecoveryIsExplicit() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), url = stateURL(root)
        let revision = try await writer.writeState(.init(), to: url, expectedRevision: nil)
        let external = try JSONEncoder().encode(StudyMaterialState(records: [material("犬")]))
        try external.write(to: url, options: .atomic)
        let local = StudyMaterialState(records: [material()])
        await #expect(throws: StudyFileError.conflict) { try await writer.writeState(local, to: url, expectedRevision: revision) }
        #expect(try Data(contentsOf: url) == external)
        #expect(try await writer.loadState(url).hasConflict)
        let marker = root.appendingPathComponent(".workspace/study-state-conflict.json")
        #expect(try StudyMaterialState.decode(Data(contentsOf: marker)) == local)
        let reopened = StudyFileWriter(), recovered = try await reopened.recoverState(url)
        #expect(!recovered.hasConflict); #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).contains { $0.hasPrefix("study-state-recovered-") })
    }
    @Test(arguments: 0..<5) @MainActor func dependencyChangesBlockCardWrites(variant: Int) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer)
        await store.open(vaultRoot: root)
        await #expect(throws: Error.self) {
            try await store.importMaterial(material()) { intent in
                let dependency = try await persist(intent, writer: writer, root: root), url = stateURL(root)
                switch variant {
                case 0: try FileManager.default.removeItem(at: url)
                case 1: try Data(#"{"schemaVersion":2,"records":[],"intents":[]}"#.utf8).write(to: url, options: .atomic)
                case 2: try Data().write(to: root.appendingPathComponent(".workspace/study-state-conflict.json"))
                case 3: try JSONEncoder().encode(StudyMaterialState()).write(to: url, options: .atomic)
                default: try Data("bad".utf8).write(to: url, options: .atomic)
                }
                return dependency
            }
        }
        #expect(store.cards.isEmpty); #expect(!FileManager.default.fileExists(atPath: cardsURL(root).path))
        #expect(await store.add(Flashcard(japanese: "手動", translation: "manual")))
    }
    @Test @MainActor func failedIntentNeverWritesCardAndReplayDoesNotOverwriteEdits() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer)
        await store.open(vaultRoot: root)
        await #expect(throws: Error.self) { try await store.importMaterial(material()) { _ in throw CocoaError(.fileWriteNoPermission) } }
        #expect(store.cards.isEmpty)
        let intent = try await store.importMaterial(material()) { try await persist($0, writer: writer, root: root) }
        #expect(store.cards.first?.materialID == intent.materialID)
        #expect(store.cards.first?.appliedMaterialOperationID == intent.id)
        var edited = try #require(store.cards.first); edited.note = "user edit"; edited.successfulReviews = 4
        #expect(await store.update(edited))
        let reopened = FlashcardStore(writer: writer); await reopened.open(vaultRoot: root)
        let state = try await writer.loadState(stateURL(root))
        try await reopened.recoverMaterialImport(intent, dependency: .init(url: stateURL(root), revision: try #require(state.revision)))
        #expect(reopened.cards.count == 1); #expect(reopened.cards.first?.note == "user edit")
        #expect(try await writer.loadState(stateURL(root)).state.intents == [intent]) // Acknowledgement may have crashed.
    }
    @Test @MainActor func durableIntentBeforeCardCommitCanResumeButDeletionCannotResurrect() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer)
        await store.open(vaultRoot: root)
        let intent = StudyAcceptanceIntent(materialID: UUID(), card: material().makeCard(), expectedCardRevision: nil, createsCard: true)
        let dependency = try await persist(intent, writer: writer, root: root)
        try await store.recoverMaterialImport(intent, dependency: dependency)
        #expect(store.cards.count == 1)
        #expect(await store.delete(id: intent.card.id))
        let reopened = FlashcardStore(writer: writer); await reopened.open(vaultRoot: root)
        await #expect(throws: StudyImportError.ambiguous) { try await reopened.recoverMaterialImport(intent, dependency: dependency) }
        #expect(reopened.cards.isEmpty)
    }
    @Test(arguments: [false, true]) @MainActor func historicalMissingTargetBlocksByteIdenticalABA(existingEmpty: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer)
        if existingEmpty { _ = try await writer.write([], to: cardsURL(root), expectedRevision: nil) }
        await store.open(vaultRoot: root)
        if !existingEmpty { #expect(await store.add(Flashcard(japanese: "手動", translation: "manual"))) }
        let before = try Data(contentsOf: cardsURL(root))
        let intent = try await store.importMaterial(material()) { try await persist($0, writer: writer, root: root) }
        #expect(intent.expectedCardRevision != nil); #expect(store.cards.contains { $0.id == intent.card.id })
        #expect(await store.delete(id: intent.card.id))
        #expect(try Data(contentsOf: cardsURL(root)) == before)
        let reopened = FlashcardStore(writer: writer); await reopened.open(vaultRoot: root)
        let state = try await writer.loadState(stateURL(root))
        await #expect(throws: StudyImportError.ambiguous) {
            try await reopened.recoverMaterialImport(intent, dependency: .init(url: stateURL(root), revision: try #require(state.revision)))
        }
        #expect(!reopened.cards.contains { $0.id == intent.card.id }); #expect(try Data(contentsOf: cardsURL(root)) == before)
    }
    @Test @MainActor func linkChecksCardCASAndPreservesExistingCard() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer), material = material()
        await store.open(vaultRoot: root)
        let original = material.makeCard(); #expect(await store.add(original))
        let intent = try await store.importMaterial(material) { try await persist($0, writer: writer, root: root) }
        #expect(!intent.createsCard); #expect(intent.card.id == original.id); #expect(store.cards == [original])
        await #expect(throws: StudyFileError.conflict) {
            try await store.importMaterial(material) { intent in
                let dependency = try await persist(intent, writer: writer, root: root)
                try JSONEncoder().encode([Flashcard(japanese: "犬", translation: "dog")]).write(to: cardsURL(root), options: .atomic)
                return dependency
            }
        }
        #expect(store.isBlocked); #expect(store.cards == [original])
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".workspace/flashcards-conflict.json").path))
    }
    @Test @MainActor func intentPlanningHoldsFIFOAndVaultSwitchCannotPublish() async throws {
        let root = root(), next = self.root(); defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: next) }
        let writer = StudyFileWriter(), store = FlashcardStore(writer: writer), gate = MaterialPersistenceGate()
        await store.open(vaultRoot: root)
        let first = Task { try await store.importMaterial(material("犬")) { intent in
            await gate.wait(); return try await persist(intent, writer: writer, root: root)
        } }
        while gate.continuation == nil { await Task.yield() }
        let existing = material().makeCard(), adding = Task { await store.add(existing) }
        await Task.yield()
        let second = Task { try await store.importMaterial(material()) { try await persist($0, writer: writer, root: root) } }
        gate.continuation?.resume(); _ = try await first.value; #expect(await adding.value)
        let linked = try await second.value
        #expect(linked.card.id == existing.id); #expect(!linked.createsCard)
        let otherGate = MaterialPersistenceGate()
        let old = Task { try await store.importMaterial(material("鳥")) { intent in
            await otherGate.wait(); return try await persist(intent, writer: writer, root: root)
        } }
        while otherGate.continuation == nil { await Task.yield() }
        let switching = Task { await store.open(vaultRoot: next) }
        while store.isLoaded { await Task.yield() }
        otherGate.continuation?.resume()
        await #expect(throws: StudyImportError.staleVault) { try await old.value }
        await switching.value; #expect(store.cards.isEmpty)
    }
}
@MainActor private final class MaterialPersistenceGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
}
