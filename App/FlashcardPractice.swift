import Foundation

enum FlashcardPracticeMode: String, CaseIterable, Identifiable {
    case cards, quiz
    var id: String { rawValue }
    var title: String { self == .cards ? "Карточки" : "Quiz" }
}

enum FlashcardSwipe {
    static func rating(x: Double, y: Double) -> FlashcardRating? {
        guard max(abs(x), abs(y)) >= 90 else { return nil }
        if abs(y) > abs(x) { return y < 0 ? .hard : nil }
        return x < 0 ? .forgot : .remembered
    }
}

enum FlashcardAnswer {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func matches(_ response: String, card: Flashcard) -> Bool {
        let answer = normalized(response)
        return !answer.isEmpty && (answer == normalized(card.japanese) ||
            (!card.reading.isEmpty && answer == normalized(card.reading)))
    }
}

struct FlashcardQuizChoice: Identifiable, Equatable {
    var text: String
    var id: String { FlashcardAnswer.normalized(text) }
}

struct FlashcardQuizQuestion: Equatable {
    var correctAnswer: String
    var choices: [FlashcardQuizChoice]

    func isCorrect(_ choice: FlashcardQuizChoice) -> Bool {
        choice.id == FlashcardAnswer.normalized(correctAnswer)
    }
}

enum FlashcardQuiz {
    static func canPractice(_ card: Flashcard, vocabulary: [Flashcard]) -> Bool {
        if card.phrasePractice?.question(for: card) != nil { return true }
        return !FlashcardAnswer.normalized(card.japanese).isEmpty &&
        !FlashcardAnswer.normalized(card.translation).isEmpty &&
        !distractors(for: card, vocabulary: vocabulary).isEmpty
    }

    static func question(for card: Flashcard, vocabulary: [Flashcard]) -> FlashcardQuizQuestion? {
        var generator = SystemRandomNumberGenerator()
        return question(for: card, vocabulary: vocabulary, using: &generator)
    }

    static func question<R: RandomNumberGenerator>(for card: Flashcard, vocabulary: [Flashcard], using generator: inout R) -> FlashcardQuizQuestion? {
        if let question = card.phrasePractice?.question(for: card) { return question }
        guard canPractice(card, vocabulary: vocabulary) else { return nil }
        let alternatives = distractors(for: card, vocabulary: vocabulary).shuffled(using: &generator).prefix(3)
        let choices = ([card.translation] + alternatives).map { FlashcardQuizChoice(text: $0) }.shuffled(using: &generator)
        return FlashcardQuizQuestion(correctAnswer: card.translation, choices: choices)
    }

    private static func distractors(for card: Flashcard, vocabulary: [Flashcard]) -> [String] {
        let word = FlashcardAnswer.normalized(card.japanese)
        // Another known translation of the same word is also a valid answer,
        // even when that translation appears on a different vocabulary entry.
        var seen = Set(vocabulary.filter { FlashcardAnswer.normalized($0.japanese) == word }
            .map { FlashcardAnswer.normalized($0.translation) })
        seen.insert(FlashcardAnswer.normalized(card.translation))
        return vocabulary.compactMap { candidate in
            let answer = FlashcardAnswer.normalized(candidate.translation)
            guard !FlashcardAnswer.normalized(candidate.japanese).isEmpty,
                  FlashcardAnswer.normalized(candidate.japanese) != word,
                  !answer.isEmpty, seen.insert(answer).inserted else { return nil }
            return candidate.translation
        }
    }
}

/// A bounded main round followed by one automatic round of mistakes.
/// Further rounds are explicit, so repeated failure never traps the learner.
struct FlashcardPracticeSession {
    private(set) var queue: [FlashcardExercise] = []
    private(set) var index = 0
    private(set) var round = 1
    private(set) var initialCount = 0
    private(set) var attemptCount = 0
    private(set) var mistakes: [FlashcardExercise] = []

    init(exercises: [FlashcardExercise] = []) {
        var seen = Set<UUID>()
        queue = exercises.filter { seen.insert($0.id).inserted }
        initialCount = queue.count
    }

    var current: FlashcardExercise? { queue.indices.contains(index) ? queue[index] : nil }
    var isComplete: Bool { current == nil }
    var remainingMistakeCount: Int { mistakes.count }

    mutating func record(_ updatedCard: Flashcard, rating: FlashcardRating) {
        guard var exercise = current, exercise.id == updatedCard.id else { return }
        exercise.card = updatedCard
        if rating == .forgot { mistakes.append(exercise) }
        attemptCount += 1
        index += 1
        if index == queue.count, round == 1, !mistakes.isEmpty { repeatMistakes() }
    }

    mutating func repeatMistakes() {
        guard !mistakes.isEmpty else { return }
        queue = mistakes
        mistakes = []
        index = 0
        round += 1
    }
}
