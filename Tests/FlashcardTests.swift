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
        #expect(forgotten.lastRating == .forgot)
        #expect(forgotten.lastReviewAt == now)

        let hard = FlashcardScheduler.review(card, rating: .hard, now: now)
        #expect(hard.intervalDays == 1)
        #expect(hard.successfulReviews == 1)

        let remembered = FlashcardScheduler.review(card, rating: .remembered, now: now)
        #expect(remembered.intervalDays == 3)
        #expect(remembered.successfulReviews == 1)
    }

    @Test func practiceRotatesThroughActiveRecallModes() {
        var card = Flashcard(
            japanese: "食べる",
            translation: "есть",
            example: "毎朝パンを食べる。"
        )
        #expect(FlashcardPracticeQueue.exercise(for: card).mode == .recognition)

        card.successfulReviews = 1
        #expect(FlashcardPracticeQueue.exercise(for: card).mode == .production)

        card.successfulReviews = 2
        let exercise = FlashcardPracticeQueue.exercise(for: card)
        #expect(exercise.mode == .cloze)
        #expect(exercise.prompt == "毎朝パンを＿＿＿。")
    }

    @Test func legacyCardsDecodeWithoutSourceMetadata() throws {
        let data = Data(#"[{"id":"9D9CFA6D-A2D1-470C-9B4B-8C4CE8FF179B","japanese":"猫","translation":"кошка","reading":"ねこ","example":"","note":"","createdAt":0,"dueAt":0,"intervalDays":0,"successfulReviews":0,"failedReviews":0}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let card = try #require(decoder.decode([Flashcard].self, from: data).first)
        #expect(card.sourcePath == nil)
        #expect(card.lastRating == nil)
    }

    @Test @MainActor func storePersistsCRUDAndDeduplicatesGeneratedCards() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let first = Flashcard(japanese: "猫", translation: "кошка", sourcePath: "日本語/Начало.md", sourceExcerpt: "猫がいます。")
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
