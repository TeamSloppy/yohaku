import Foundation
import Testing
@testable import StudyIntelligence
@testable import Yohaku

struct FlashcardSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func ratingsProduceDeterministicIntervals() {
        let card = Flashcard(japanese: "食べる", translation: "есть")

        let forgotten = FlashcardScheduler.review(card, rating: .forgot, now: now)
        #expect(forgotten.intervalDays == 0)
        #expect(forgotten.failedReviews == 1)
        #expect(forgotten.dueAt == now.addingTimeInterval(600))

        let hard = FlashcardScheduler.review(card, rating: .hard, now: now)
        #expect(hard.intervalDays == 1)
        #expect(hard.successfulReviews == 1)

        let remembered = FlashcardScheduler.review(card, rating: .remembered, now: now)
        #expect(remembered.intervalDays == 3)
        #expect(remembered.successfulReviews == 1)
    }

    @Test @MainActor func storePersistsCRUDAndDeduplicatesGeneratedCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let first = Flashcard(japanese: "猫", translation: "кошка")
        await store.add([first, Flashcard(japanese: "猫", translation: "кошка")])
        #expect(store.cards.count == 1)

        var edited = try #require(store.cards.first)
        edited.note = "животное"
        await store.update(edited)

        let restored = FlashcardStore()
        await restored.open(vaultRoot: root)
        #expect(restored.cards == [edited])
        await restored.delete(id: edited.id)
        #expect(restored.cards.isEmpty)
    }
}

struct FlashcardGenerationTests {
    @Test func parserExtractsValidUniqueCardsAndHonorsLimit() throws {
        let response = """
        ```json
        [
          {"japanese":"猫","reading":"ねこ","translation":"кошка","example":"猫がいます。","note":""},
          {"japanese":"猫","reading":"ねこ","translation":"кошка","example":"duplicate","note":""},
          {"japanese":"犬","reading":"いぬ","translation":"собака","example":"犬がいます。","note":""}
        ]
        ```
        """
        let cards = try FlashcardGenerationParser.parse(response, limit: 10)
        #expect(cards.map(\.japanese) == ["猫", "犬"])
        #expect(try FlashcardGenerationParser.parse(response, limit: 1).count == 1)
    }

    @Test func parserRejectsNonJSONAndDropsInvalidCards() throws {
        #expect(throws: Error.self) { try FlashcardGenerationParser.parse("нет массива", limit: 10) }
        let response = #"[{"japanese":"","reading":"","translation":"пусто","example":"","note":""}]"#
        #expect(try FlashcardGenerationParser.parse(response, limit: 10).isEmpty)
    }
}
