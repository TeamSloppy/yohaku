import Foundation
import Testing
@testable import Yohaku

struct CourseTests {
    @Test func eightyPercentIsRequiredForEachSkill() throws {
        var module = try #require(CourseCatalog.load().first); module.items = Array(module.items.prefix(5))
        let steps = CourseCatalog.steps(module, checkpoint: true, progress: .init(), duration: .long)
        for mistakes in [1,2] {
            var errors: [CourseSkill: Int] = [:]
            let answers = steps.map { step -> LearningAnswer in
                let skill = step.courseTask!.skill
                errors[skill, default: 0] += 1
                return .init(stepID: step.id, rating: errors[skill]! <= mistakes ? .forgot : .remembered, response: "")
            }
            let session = LearningSession(duration: .long, steps: steps, answers: answers, completedAt: Date(),
                course: .init(moduleID: module.id, catalogVersion: 1, checkpoint: true))
            #expect(CourseCatalog.checkpoint(session, now: Date())?.passed == (mistakes == 1))
        }
    }
    @Test @MainActor func checkpointNeedsEverySkillAndResumesWithoutDoubleCounting() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningStore(); await store.open(root)
        let modules = try CourseCatalog.load(), module = try #require(modules.first)
        try await store.startCourse(module, checkpoint: true, duration: .short, modules: modules, ifCurrent: { true })
        let initial = try #require(store.state.courseSession)
        await store.open(root); #expect(store.state.courseSession == initial)
        while let session = store.state.courseSession, let step = session.current {
            let rating: FlashcardRating = step.courseTask?.skill == .writing ? .forgot : .remembered
            try await store.answerCourse(sessionID: session.id, stepID: step.id, rating: rating, response: "test", ifCurrent: { true })
            try await store.answerCourse(sessionID: session.id, stepID: step.id, rating: rating, response: "duplicate", ifCurrent: { true })
        }
        #expect(store.state.course?.completed.isEmpty == true)
        var next = module; next.id = "next"
        #expect(!CourseCatalog.unlocked(next.id, modules: [module,next], progress: store.state.course ?? .init()))
        #expect(store.state.course?.checks.count == 1)
        #expect(store.state.course?.checks.first?.scores[.reading] == 1)
        #expect(store.state.course?.checks.first?.scores[.writing] == 0)
        #expect(store.state.course?.mistakes.isEmpty == false)
        for day in [0.0, 86_400.0] {
            try await store.startCourse(module, checkpoint: true, duration: .short, modules: modules, ifCurrent: { true })
            while let session = store.state.courseSession, let step = session.current {
                try await store.answerCourse(sessionID: session.id, stepID: step.id, rating: .remembered, response: "", now: Date(timeIntervalSince1970: 1_700_000_000 + day), ifCurrent: { true })
            }
        }
        #expect(store.state.course?.completed.contains(module.id) == true)
        #expect(CourseCatalog.unlocked(next.id, modules: [module,next], progress: store.state.course ?? .init()))
        #expect(store.state.course?.reinforced(module.id) == true)
    }
    @Test @MainActor func failedWritingCannotBecomeCorrectAfterReopen() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LearningStore(); await store.open(root)
        var module = try #require(CourseCatalog.load().first); module.items = Array(module.items.prefix(1))
        try await store.startCourse(module, checkpoint: true, duration: .short, modules: [module], ifCurrent: { true })
        let session = try #require(store.state.courseSession), step = try #require(session.current)
        try await store.flagCourseFailure(sessionID: session.id, stepID: step.id, ifCurrent: { true })
        await store.open(root)
        try await store.answerCourse(sessionID: session.id, stepID: step.id, rating: .remembered, response: "", ifCurrent: { true })
        #expect(store.state.courseSession?.answers.first?.rating == .forgot)
    }
    @Test @MainActor func courseCardImportIsIdempotentAndPreservesManualHistory() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(); try await workspace.openVault(root, remember: false)
        let manual = Flashcard(japanese: "いえ", reading: "いえ", translation: "Дом", successfulReviews: 3)
        #expect(await workspace.flashcards.add(manual))
        let incoming = try #require(CourseCatalog.load().first).items.map(\.card)
        #expect(await workspace.flashcards.addCourseCards(incoming, ifCurrent: { true }))
        #expect(await workspace.flashcards.addCourseCards(incoming, ifCurrent: { true }))
        let saved = try #require(workspace.flashcards.cards.first { $0.id == manual.id })
        #expect(saved.successfulReviews == 3)
        #expect(saved.courseItemID == "word:いえ")
        #expect(workspace.flashcards.cards.count == incoming.count)
    }
}
