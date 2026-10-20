import Foundation
import Testing
@testable import Yohaku

struct LearningSessionTests {
    @Test @MainActor func twoSessionsResumeAndLeaveCardBytesUntouched() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(); try await workspace.openVault(root, remember: false)
        let card = Flashcard(japanese: "猫", reading: "ねこ", translation: "Кошка", dueAt: .distantFuture, successfulReviews: 2)
        #expect(await workspace.flashcards.add(card))
        let url = root.appendingPathComponent(".workspace/flashcards.json")
        let before = try Data(contentsOf: url)
        for _ in 0..<2 {
            let plan = ExtraPracticePlanner.plan(cards: workspace.flashcards.cards, materials: [], state: workspace.learning.state, duration: .short)
            #expect(plan.count == 1)
            try await workspace.learning.start(plan, duration: .short, ifCurrent: { true })
            let session = try #require(workspace.learning.state.session)
            await workspace.learning.open(root)
            #expect(workspace.learning.state.session == session)
            try await workspace.learning.answer(sessionID: session.id, stepID: plan[0].id, rating: .forgot, response: "", ifCurrent: { true })
            try await workspace.learning.answer(sessionID: session.id, stepID: plan[0].id, rating: .forgot, response: "duplicate", ifCurrent: { true })
            #expect(workspace.learning.state.session?.answers.count == 1)
            #expect(workspace.learning.state.session?.isComplete == true)
            #expect(try Data(contentsOf: url) == before)
        }
        #expect(workspace.learning.state.evidence.count == 1)
        #expect(workspace.learning.state.evidence.first?.rating == .forgot)
    }
    @Test func plannerUsesStudiedWordsAndPrioritizesMistakesThenVariety() {
        let a = Flashcard(japanese: "猫", translation: "Кошка", successfulReviews: 2)
        let b = Flashcard(japanese: "犬", translation: "Собака", successfulReviews: 2)
        let unused = Flashcard(japanese: "家", translation: "Дом")
        var state = LearningState(); state.recentCardIDs = [a.id]
        var steps = ExtraPracticePlanner.plan(cards: [a,b,unused], materials: [], state: state, duration: .short)
        #expect(steps.map(\.card.id) == [b.id,a.id])
        state.evidence = [.init(cardID: a.id, rating: .forgot, practicedAt: Date())]
        steps = ExtraPracticePlanner.plan(cards: [a,b,unused], materials: [], state: state, duration: .short)
        #expect(steps.map(\.card.id) == [a.id,b.id])
    }
    @Test @MainActor func conflictAndFutureVersionNeverOverwriteSavedState() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningStore(); await store.open(root)
        let steps = [LearningStep(card: .init(japanese: "猫", translation: "Кошка"), mode: .recognition, reason: "test")]
        try await store.start(steps, duration: .short, ifCurrent: { true })
        let url = root.appendingPathComponent(".workspace/learning-state.json")
        var external = store.state; external.recentCardIDs = []
        let bytes = try StudyFileWriter.encode(external); try bytes.write(to: url)
        await #expect(throws: StudyFileError.conflict) { try await store.change(ifCurrent: { true }) { $0.recentCardIDs = [UUID()] } }
        #expect(store.blocked)
        #expect(try Data(contentsOf: url) == bytes)
        await store.recover(); #expect(!store.blocked)
        var future = external; future.schemaVersion = 99
        let futureBytes = try StudyFileWriter.encode(future); try futureBytes.write(to: url)
        await store.open(root); #expect(store.blocked)
        #expect(try Data(contentsOf: url) == futureBytes)
    }
    @Test @MainActor func staleVaultCannotPublishOrWriteAttempt() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningStore(); await store.open(root)
        await #expect(throws: StudyImportError.staleVault) {
            try await store.change(ifCurrent: { false }) { $0.recentCardIDs = [UUID()] }
        }
        #expect(store.state == LearningState())
    }
}
