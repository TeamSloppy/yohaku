import Foundation
import Testing
import StudyCore
@testable import Yohaku

struct FlashcardPersistenceTests {
    private func root() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func file(_ root: URL) -> URL { root.appendingPathComponent(".workspace/flashcards.json") }
    private func card(_ word: String = "猫") -> Flashcard { Flashcard(japanese: word, translation: word) }

    @Test @MainActor func canvasProvenanceRoundTripsAndLegacyCardsDecode() throws {
        var value = card(); value.sourcePageID = UUID(); value.sourceRegion = Rect(x: -20, y: 0, width: 300, height: 200)
        value.sourceTextOrigin = .confirmedTranscription; value.sourceExcerpt = "猫"
        let restored = try JSONDecoder().decode(Flashcard.self, from: JSONEncoder().encode(value))
        #expect(restored == value); #expect(FlashcardDraft(card: restored).makeCard() == value)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        object.removeValue(forKey: "sourceRegion"); object.removeValue(forKey: "sourceTextOrigin")
        let legacy = try JSONDecoder().decode(Flashcard.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.sourceRegion == nil); #expect(legacy.sourceTextOrigin == nil)
    }

    @Test @MainActor func concurrentReviewsDeriveFromCommittedState() async throws {
        let writer = PausingStudyWriter()
        let store = FlashcardStore(writer: writer)
        await store.open(vaultRoot: root())
        let original = card()
        #expect(await store.add(original))
        await writer.pauseNextWrite()
        let first = Task { await store.review(id: original.id, rating: .remembered) }
        await writer.waitUntilPaused()
        let second = Task { await store.review(id: original.id, rating: .hard) }
        #expect(store.cards == [original])
        await writer.resume()
        #expect(await first.value)
        #expect(await second.value)
        #expect(store.cards.first?.successfulReviews == 2)
        #expect(await writer.snapshot().cards == store.cards)
    }

    @Test @MainActor func queuedEditorDraftPreservesCommittedReviewHistory() async {
        let writer = PausingStudyWriter()
        let store = FlashcardStore(writer: writer)
        await store.open(vaultRoot: root())
        let original = card()
        #expect(await store.add(original))
        await writer.pauseNextWrite()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let reviewing = Task { await store.review(id: original.id, rating: .forgot, now: now) }
        await writer.waitUntilPaused()
        var draft = original
        draft.note = "edited while review was saving"
        let editing = Task { await store.update(draft) }
        await writer.resume()
        #expect(await reviewing.value)
        #expect(await editing.value)
        var expected = FlashcardScheduler.review(original, rating: .forgot, now: now)
        expected.note = draft.note
        #expect(store.cards == [expected])
        #expect(await writer.snapshot().cards == [expected])
    }

    @Test @MainActor func failedMutationsNeverPublishCandidateOrNotify() async throws {
        let writer = PausingStudyWriter()
        var notifications = 0
        let store = FlashcardStore(writer: writer) { _ in notifications += 1 }
        await store.open(vaultRoot: root())
        let original = card()
        #expect(await store.add(original))
        let baseline = notifications
        var updated = original
        updated.note = "changed"
        for operation in 0..<5 {
            await writer.failNextWrite()
            let saved: Bool
            switch operation {
            case 0: saved = await store.add(card("犬"))
            case 1: saved = await store.add([card("鳥")])
            case 2: saved = await store.update(updated)
            case 3: saved = await store.delete(id: original.id)
            default: saved = await store.review(id: original.id, rating: .forgot)
            }
            #expect(!saved)
            #expect(store.cards == [original])
            #expect(notifications == baseline)
        }
    }

    @Test @MainActor func queuedAcceptanceRechecksSourceValidity() async {
        let writer = PausingStudyWriter()
        let controlled = FlashcardStore(writer: writer)
        await controlled.open(vaultRoot: root()); await writer.pauseNextWrite()
        let first = Task { await controlled.add(card()) }; await writer.waitUntilPaused()
        var valid = true, started = false
        let queued = Task { started = true; return await controlled.add([card("犬")], ifCurrent: { valid }) }
        while !started { await Task.yield() }
        valid = false; await writer.resume()
        #expect(await first.value); #expect(!(await queued.value))
        #expect(controlled.cards.map(\.japanese) == ["猫"])
    }

    @Test @MainActor func staleWriteAndQueuedMutationCannotPublishIntoNewVault() async throws {
        let writer = PausingStudyWriter()
        var published: [[Flashcard]] = []
        let store = FlashcardStore(writer: writer) { published.append($0) }
        await store.open(vaultRoot: root())
        await writer.pauseNextWrite()
        let old = Task { await store.add(card()) }
        await writer.waitUntilPaused()
        var queuedStarted = false
        let queued = Task { queuedStarted = true; return await store.add(card("犬")) }
        while !queuedStarted { await Task.yield() }
        let reopened = Task { await store.open(vaultRoot: root()) }
        while store.isLoaded { await Task.yield() }
        await writer.resume()
        #expect(!(await old.value))
        #expect(!(await queued.value))
        await reopened.value
        #expect(store.cards.isEmpty)
        #expect(published == [[], []])
    }

    @Test @MainActor func staleLoadCannotReplaceNewVault() async throws {
        let writer = PausingStudyWriter()
        let store = FlashcardStore(writer: writer)
        await writer.pauseNextLoad()
        let first = Task { await store.open(vaultRoot: root()) }
        await writer.waitUntilPaused()
        var secondStarted = false
        let second = Task { secondStarted = true; await store.open(vaultRoot: root()) }
        while !secondStarted { await Task.yield() }
        await writer.resume()
        await first.value
        await second.value
        #expect(store.isLoaded)
        #expect(!store.isBlocked)
        #expect(store.cards.isEmpty)
    }

    @Test @MainActor func callbacksFinishBeforeNextVaultNotification() async {
        let writer = PausingStudyWriter()
        var events: [String] = []
        let store = FlashcardStore(writer: writer) { cards in
            if cards.isEmpty { events.append("empty"); return }
            events.append("old-start")
            await writer.holdCallback()
            events.append("old-end")
        }
        await store.open(vaultRoot: root())
        let adding = Task { await store.add(card()) }
        await writer.waitUntilPaused()
        let opening = Task { await store.open(vaultRoot: root()) }
        while store.isLoaded { await Task.yield() }
        await writer.resume()
        #expect(!(await adding.value))
        await opening.value
        #expect(events == ["empty", "old-start", "old-end", "empty"])
        #expect(store.cards.isEmpty)
    }

    @Test @MainActor func externalRevisionPreservesBothVersionsAndRequiresExplicitRecovery() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let original = card()
        #expect(await store.add(original))
        let external = card("犬")
        let externalBytes = try JSONEncoder().encode([external])
        try externalBytes.write(to: file(root), options: .atomic)
        #expect(!(await store.review(id: original.id, rating: .forgot)))
        #expect(store.cards == [original])
        #expect(store.isBlocked)
        #expect(try Data(contentsOf: file(root)) == externalBytes)
        let marker = root.appendingPathComponent(".workspace/flashcards-conflict.json")
        let local = try JSONDecoder().decode([Flashcard].self, from: Data(contentsOf: marker))
        #expect(local.first?.failedReviews == 1)
        let reopened = FlashcardStore()
        await reopened.open(vaultRoot: root)
        #expect(reopened.isBlocked)
        #expect(!(await reopened.add(card("鳥"))))
        #expect(await reopened.recoverSavedVersion())
        #expect(reopened.cards == [external])
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let copies = try FileManager.default.contentsOfDirectory(atPath: marker.deletingLastPathComponent().path)
        #expect(copies.contains { $0.hasPrefix("flashcards-external-") })
        #expect(copies.contains { $0.hasPrefix("flashcards-recovered-") })
        #expect(await reopened.add(card("鳥")))
    }

    @Test @MainActor func malformedFileCannotBeReplacedByEmptyLibrary() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: file(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("broken JSON".utf8)
        try bytes.write(to: file(root))
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        #expect(store.isBlocked)
        #expect(!(await store.add(card())))
        #expect(!(await store.recoverSavedVersion()))
        #expect(try Data(contentsOf: file(root)) == bytes)
    }

    @Test @MainActor func legacyArrayLoadsAndRoundTripsWithoutMigration() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: file(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data(#"[{"id":"9D9CFA6D-A2D1-470C-9B4B-8C4CE8FF179B","japanese":"猫","translation":"кошка","reading":"ねこ","example":"","note":"","createdAt":0,"dueAt":0,"intervalDays":0,"successfulReviews":0,"failedReviews":0}]"#.utf8)
        try bytes.write(to: file(root))
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        #expect(store.cards.first?.sourcePath == nil)
        let id = try #require(store.cards.first?.id)
        #expect(await store.review(id: id, rating: .remembered))
        let restored = FlashcardStore()
        await restored.open(vaultRoot: root)
        #expect(restored.cards == store.cards)
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file(root))) is [Any])
    }
}

private actor PausingStudyWriter: StudyFileWriting {
    private var state: [URL: StudyFileSnapshot] = [:]
    private var pauseWrite = false
    private var pauseLoad = false
    private var shouldFail = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    private var last = StudyFileSnapshot(cards: [], revision: nil, hasConflict: false)
    func pauseNextWrite() { pauseWrite = true }
    func pauseNextLoad() { pauseLoad = true }
    func failNextWrite() { shouldFail = true }
    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func resume() { pending?.resume(); pending = nil }
    func snapshot() -> StudyFileSnapshot { last }
    func holdCallback() async { await pause() }
    private func pause() async {
        await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
    }
    func load(_ url: URL) async throws -> StudyFileSnapshot {
        let snapshot = state[url] ?? StudyFileSnapshot(cards: [], revision: nil, hasConflict: false)
        if pauseLoad { pauseLoad = false; await pause() }
        return snapshot
    }
    func recover(_ url: URL) async throws -> StudyFileSnapshot { try await load(url) }
    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) async throws -> String {
        if pauseWrite { pauseWrite = false; await pause() }
        if shouldFail { shouldFail = false; throw CocoaError(.fileWriteNoPermission) }
        guard state[url]?.revision == expectedRevision else { throw StudyFileError.conflict }
        let revision = UUID().uuidString
        last = StudyFileSnapshot(cards: cards, revision: revision, hasConflict: false)
        state[url] = last
        return revision
    }
}
