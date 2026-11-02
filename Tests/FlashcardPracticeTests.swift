import Foundation
import Testing
@testable import Yohaku

struct FlashcardPracticeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func card(_ word: String = "猫", translation: String = "кошка") -> Flashcard {
        Flashcard(japanese: word, translation: translation, dueAt: now)
    }

    @Test func manualSelectionUsesNewOrAllWordsAndInclusiveStableRangesWithoutLimit() {
        var cards = (0..<43).map { index in
            var word = card("word-\(index)")
            word.createdAt = now.addingTimeInterval(Double(index))
            word.dueAt = now.addingTimeInterval(86_400)
            return word
        }
        cards[1].failedReviews = 1
        cards[2].successfulReviews = 1
        let all = FlashcardStudySelection(scope: .all)
        #expect(all.cards(in: cards.reversed(), now: now).map(\.id) == cards.map(\.id))
        #expect(all.cards(in: cards, now: now).count == 43)
        let new = FlashcardStudySelection(scope: .new)
        #expect(new.cards(in: cards, now: now).count == 41)
        #expect(!new.cards(in: cards, now: now).contains { $0.id == cards[1].id || $0.id == cards[2].id })
        let range = FlashcardStudySelection(scope: .new, first: 2, last: 4)
        #expect(range.cards(in: cards.reversed(), now: now).map(\.id) == Array(cards[3...5]).map(\.id))
        #expect(FlashcardStudySelection(scope: .due).cards(in: cards, now: now).isEmpty)
        cards[4].dueAt = now
        #expect(FlashcardStudySelection(scope: .due).cards(in: cards, now: now).map(\.id) == [cards[4].id])
    }

    @Test func manualRangesRejectInvalidBoundsAndResolveDateTiesDeterministically() {
        var cards = [card(), card("犬")]
        cards[1].createdAt = cards[0].createdAt
        let all = FlashcardStudySelection(scope: .all)
        #expect(all.cards(in: cards).map(\.id) == all.cards(in: cards.reversed()).map(\.id))
        for bounds in [(0, 1), (2, 1), (1, 3), (-1, 2)] {
            #expect(FlashcardStudySelection(scope: .all, first: bounds.0, last: bounds.1).cards(in: cards).isEmpty)
        }
        #expect(all.cards(in: []).isEmpty)
        #expect(FlashcardStudySelection(scope: .all, first: 2, last: 2).cards(in: cards).count == 1)
    }

    @Test func kanaPromptNeverFallsBackToRomajiTranslationOrKanji() {
        var word = card("猫")
        word.reading = "neko"
        #expect(FlashcardStudyPrompt.kana(for: word) == nil)
        word.reading = "ねこ"
        #expect(FlashcardStudyPrompt.kana(for: word) == "ねこ")
        word.japanese = "ｺｰﾋｰ"
        #expect(FlashcardStudyPrompt.kana(for: word) == "コーヒー")
        word.japanese = "お茶"
        word.reading = "おちゃ (ocha)"
        #expect(FlashcardStudyPrompt.kana(for: word) == nil)
        word.reading = "おちゃ"
        word.successfulReviews = 1
        let exercise = FlashcardStudyPrompt.kana.exercise(for: word)
        #expect(exercise.mode == .recognition)
        #expect(FlashcardStudyPrompt.kana.text(for: exercise) == "おちゃ")
        #expect(FlashcardStudyPrompt.word.text(for: exercise) == "お茶")
        #expect(FlashcardStudyPrompt.mixed.exercise(for: word).mode == .production)
    }

    @Test func browsingMovesBothWaysWithoutChangingReviewHistoryOrBounds() {
        let cards = [card("ねこ"), card("いぬ")]
        var browse = FlashcardBrowseSession(exercises: cards.map { FlashcardStudyPrompt.kana.exercise(for: $0) })
        #expect(!browse.canGoBack)
        browse.move(-1)
        #expect(browse.current?.id == cards[0].id)
        browse.move(1)
        #expect(!browse.canGoForward)
        #expect(browse.current?.id == cards[1].id)
        browse.move(1)
        #expect(browse.index == 1)
        browse.move(-1)
        #expect(browse.index == 0)
        #expect(browse.exercises.map(\.card) == cards)
        #expect(FlashcardStudySelection(scope: .new).cards(in: browse.exercises.map(\.card)).count == 2)
    }

    @Test func suppliedSelectionPreservesMoreThanTwentyAndResolvesOnlyCurrentIDs() {
        let cards = (0..<30).map { card("word-\($0)") }
        let supplied = cards.reversed().map { FlashcardExercise(card: $0, mode: .production) }
        let resolved = DailyLessonPlanner.resolve(supplied, cards: cards, materials: nil, now: now)
        #expect(resolved.map(\.id) == supplied.map(\.id))
        #expect(FlashcardPracticeSession(exercises: resolved).initialCount == 30)
        var changed = cards
        changed.removeLast()
        changed[0].dueAt = now.addingTimeInterval(1)
        changed[1].translation = "updated"
        let filtered = DailyLessonPlanner.resolve(supplied + supplied, cards: changed + [card("unselected")], materials: nil, now: now)
        #expect(filtered.count == 28)
        #expect(filtered.map(\.id) == supplied.dropFirst().dropLast().map(\.id))
        #expect(filtered.last?.card.translation == "updated")
        #expect(filtered.allSatisfy { $0.mode == .production })
    }

    @Test func extraPracticeIncludesFutureCardsAndSupportsLargeRounds() {
        let cards = (0..<80).map { index in
            var word = card("word-\(index)")
            word.dueAt = now.addingTimeInterval(86_400)
            return word
        }
        #expect(FlashcardPracticeQueue.exercises(for: cards, now: now, limit: cards.count).isEmpty)
        let exercises = FlashcardPracticeQueue.exercises(for: cards, now: now, limit: cards.count, includeFuture: true)
        #expect(exercises.count == 80)
        #expect(Set(exercises.map(\.id)) == Set(cards.map(\.id)))
        #expect(exercises.allSatisfy { $0.card.dueAt == now.addingTimeInterval(86_400) })
        #expect(FlashcardPracticeSession(exercises: exercises).initialCount == 80)
    }

    @Test func swipeDirectionsAndThresholds() {
        #expect(FlashcardSwipe.rating(x: -120, y: 5) == .forgot)
        #expect(FlashcardSwipe.rating(x: 120, y: -5) == .remembered)
        #expect(FlashcardSwipe.rating(x: 5, y: -120) == .hard)
        #expect(FlashcardSwipe.rating(x: 5, y: 120) == nil)
        #expect(FlashcardSwipe.rating(x: 40, y: -40) == nil)
    }

    @Test func mistakesReturnAfterMainRoundWithSameExerciseAndUpdatedHistory() throws {
        let first = card()
        let second = card("犬", translation: "собака")
        var session = FlashcardPracticeSession(exercises: [
            FlashcardExercise(card: first, mode: .production),
            FlashcardExercise(card: second, mode: .recognition)
        ])
        let failed = FlashcardScheduler.review(first, rating: .forgot, now: now)
        session.record(failed, rating: .forgot)
        #expect(session.current?.id == second.id)
        #expect(session.round == 1)
        session.record(FlashcardScheduler.review(second, rating: .remembered, now: now), rating: .remembered)
        #expect(session.round == 2)
        #expect(session.queue.count == 1)
        let retry = try #require(session.current)
        #expect(retry.mode == .production)
        #expect(retry.card.failedReviews == 1)
        session.record(FlashcardScheduler.review(retry.card, rating: .remembered, now: now), rating: .remembered)
        #expect(session.isComplete)
        #expect(session.initialCount == 2)
        #expect(session.attemptCount == 3)
        #expect(session.remainingMistakeCount == 0)
    }

    @Test func repeatedMistakesEndAutomaticallyAndCanBeRetriedExplicitly() throws {
        let original = card()
        var session = FlashcardPracticeSession(exercises: FlashcardPracticeQueue.exercises(for: [original], now: now))
        let failed = FlashcardScheduler.review(original, rating: .forgot, now: now)
        session.record(failed, rating: .forgot)
        #expect(session.round == 2)
        let failedAgain = FlashcardScheduler.review(failed, rating: .forgot, now: now)
        session.record(failedAgain, rating: .forgot)
        #expect(session.isComplete)
        #expect(session.remainingMistakeCount == 1)
        #expect(session.attemptCount == 2)
        session.repeatMistakes()
        #expect(session.round == 3)
        #expect(session.current?.card.failedReviews == 2)
        session.record(FlashcardScheduler.review(failedAgain, rating: .remembered, now: now), rating: .remembered)
        #expect(session.isComplete)
        #expect(session.remainingMistakeCount == 0)
    }

    @Test func recoveryGetsShortIntervalAndNormalSuccessKeepsGrowing() {
        let failed = FlashcardScheduler.review(card(), rating: .forgot, now: now)
        let recovered = FlashcardScheduler.review(failed, rating: .remembered, now: now)
        #expect(recovered.intervalDays == 1)
        #expect(recovered.failedReviews == 1)
        let remembered = FlashcardScheduler.review(recovered, rating: .remembered, now: now)
        #expect(remembered.intervalDays > recovered.intervalDays)
    }

    @Test func weightedSessionsPreferNewAndFailedWordsAndExcludeFutureCards() {
        let fresh = card()
        var familiar = card("犬", translation: "собака")
        familiar.successfulReviews = 20
        familiar.intervalDays = 30
        familiar.lastRating = .remembered
        var failed = familiar
        failed.id = UUID()
        failed.lastRating = .forgot
        failed.failedReviews = 10
        #expect(FlashcardPracticeQueue.priority(of: fresh, now: now) > FlashcardPracticeQueue.priority(of: familiar, now: now))
        #expect(FlashcardPracticeQueue.priority(of: failed, now: now) > FlashcardPracticeQueue.priority(of: familiar, now: now))
        var overdue = familiar
        overdue.dueAt = now.addingTimeInterval(-90 * 86_400)
        #expect(FlashcardPracticeQueue.priority(of: overdue, now: now) > FlashcardPracticeQueue.priority(of: familiar, now: now))
        var future = fresh
        future.id = UUID()
        future.dueAt = now.addingTimeInterval(60)
        var generator = SeededRandom(state: 42)
        var freshSelections = 0
        for _ in 0..<1000 {
            let queue = FlashcardPracticeQueue.exercises(for: [fresh, familiar, future], now: now, limit: 1, using: &generator)
            #expect(queue.count == 1)
            #expect(queue.first?.id != future.id)
            if queue.first?.id == fresh.id { freshSelections += 1 }
        }
        #expect(freshSelections > 750)
        let batch = (0..<30).map { card("word-\($0)") }
        let queue = FlashcardPracticeQueue.exercises(for: batch, now: now, limit: 20, using: &generator)
        #expect(queue.count == 20)
        #expect(Set(queue.map(\.id)).count == 20)
        #expect(FlashcardPracticeQueue.exercises(for: batch, now: now, limit: 0).isEmpty)
    }

    @Test func quizUsesDistinctAnswersAndHandlesSmallAndHandwrittenVocabulary() throws {
        let original = card()
        var generator = SeededRandom(state: 7)
        #expect(FlashcardQuiz.question(for: original, vocabulary: [original], using: &generator) == nil)
        let dog = card("犬", translation: "собака")
        let dogDuplicate = card("いぬ", translation: " СОБАКА ")
        let sameMeaning = card("ねこ", translation: "кошка")
        let sameWord = card("猫", translation: "кот")
        let alternateSpelling = card("ネコ", translation: "кот")
        let question = try #require(FlashcardQuiz.question(for: original, vocabulary: [original, dog, dogDuplicate, sameMeaning, sameWord, alternateSpelling], using: &generator))
        #expect(question.choices.count == 2)
        #expect(question.choices.filter { question.isCorrect($0) }.count == 1)
        #expect(Set(question.choices.map(\.id)).count == 2)
        #expect(!question.choices.contains { $0.text == "кот" })
        let handwriting = card("", translation: "от руки")
        #expect(!FlashcardQuiz.canPractice(handwriting, vocabulary: [dog]))
        #expect(FlashcardQuiz.question(for: dog, vocabulary: [handwriting]) == nil)
        let vocabulary = [original, dog, card("鳥", translation: "птица"), card("魚", translation: "рыба"), card("牛", translation: "корова")]
        #expect(FlashcardQuiz.question(for: original, vocabulary: vocabulary)?.choices.count == 4)
    }

    @Test func typedAnswersAcceptReadingAndWidthDifferences() {
        var word = card("猫")
        word.reading = "ねこ"
        #expect(FlashcardAnswer.matches(" ねこ\n", card: word))
        #expect(FlashcardAnswer.matches("猫", card: word))
        #expect(!FlashcardAnswer.matches("犬", card: word))
        #expect(!FlashcardAnswer.matches("", card: word))
        word.japanese = "カタカナ"
        #expect(FlashcardAnswer.matches("ｶﾀｶﾅ", card: word))
    }

    @Test @MainActor func failedReviewSavePreservesProgressAndSuccessfulReviewPersists() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore()
        await store.open(vaultRoot: root)
        let original = card()
        #expect(await store.add(original))
        let file = root.appendingPathComponent(".workspace/flashcards.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(await store.review(id: original.id, rating: .forgot, now: now) == false)
        #expect(store.cards == [original])
        #expect(store.error != nil)
        try FileManager.default.removeItem(at: file)
        // Restore the baseline after the simulated write failure; deletion is an external revision.
        try JSONEncoder().encode([original]).write(to: file)
        #expect(await store.recoverSavedVersion())
        #expect(await store.review(id: original.id, rating: .forgot, now: now))
        let restored = FlashcardStore()
        await restored.open(vaultRoot: root)
        #expect(restored.cards.first?.failedReviews == 1)
        #expect(restored.cards.first?.lastRating == .forgot)
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
