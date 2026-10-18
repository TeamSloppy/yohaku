import Foundation
import Observation
import StudyIntelligence

struct PhrasePractice: Codable, Equatable, Sendable {
    let prompt: String
    let answer: String
    let choices: [String]
    let words: [PhraseWord]
    let generatedAt: Date

    var signature: String { words.map { $0.id.uuidString }.joined(separator: "/") + "|" + FlashcardAnswer.normalized(answer) }
    static func isKnown(_ card: Flashcard) -> Bool {
        card.phrasePractice == nil && card.successfulReviews >= 2 && card.lastRating == .remembered &&
        !card.japanese.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && card.japanese.count <= 80 &&
        !card.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && card.translation.count <= 240 && card.reading.count <= 240
    }
    static func word(_ card: Flashcard) -> PhraseWord {
        .init(id: card.id, japanese: card.japanese, reading: card.reading, translation: card.translation)
    }
    static func inputs(_ cards: [Flashcard]) -> [PhraseWord] {
        var seen = Set<String>()
        return cards.sorted {
            let a = $0.lastReviewAt ?? $0.createdAt, b = $1.lastReviewAt ?? $1.createdAt
            return a == b ? $0.id.uuidString < $1.id.uuidString : a > b
        }.filter { isKnown($0) && seen.insert(FlashcardAnswer.normalized($0.japanese)).inserted }.prefix(24).map(word)
    }
    static func card(_ phrase: ComposedPhrase, kana: Set<String>, now: Date) -> Flashcard {
        let kanaOnly = !phrase.reading.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && phrase.reading.allSatisfy { $0.isWhitespace || kana.contains(String($0)) }
        var card = Flashcard(japanese: kanaOnly ? phrase.reading : phrase.japanese, reading: phrase.reading,
            translation: phrase.translation, note: "Составлено ИИ из знакомых слов. " + phrase.explanation, createdAt: now, dueAt: now)
        card.phrasePractice = .init(prompt: card.japanese, answer: card.translation,
            choices: ([phrase.translation] + phrase.alternatives).shuffled(), words: phrase.words, generatedAt: now)
        return card
    }
    func question(for card: Flashcard) -> FlashcardQuizQuestion? {
        guard prompt == card.japanese, answer == card.translation, !prompt.isEmpty, prompt.count <= 240, !answer.isEmpty, answer.count <= 240,
              choices.count == 4, choices.allSatisfy({ !$0.isEmpty && $0.count <= 240 }),
              Set(choices.map(FlashcardAnswer.normalized)).count == 4,
              choices.contains(answer), (2...4).contains(words.count) else { return nil }
        return .init(correctAnswer: answer, choices: choices.map { .init(text: $0) })
    }
}

@MainActor @Observable final class StudyLearningProfile {
    private let defaults: UserDefaults
    private(set) var knownKana: Set<String>
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? (ProcessInfo.processInfo.arguments.contains("--ui-testing")
            ? UserDefaults(suiteName: "yohaku-ui-profile-" + (ProcessInfo.processInfo.environment["YOHHAKU_TEST_VAULT"] ?? UUID().uuidString))! : .standard)
        knownKana = Set(self.defaults.stringArray(forKey: "known-kana") ?? []).filter(Self.isKana)
    }
    private static func isKana(_ value: String) -> Bool {
        value.count == 1 && value.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) || $0.value == 0x30FC }
    }
    func recordKana(_ symbol: String) {
        guard Self.isKana(symbol), knownKana.insert(symbol).inserted else { return }
        defaults.set(knownKana.sorted(), forKey: "known-kana")
    }
    func generated(vault: String, day: String) -> Bool { defaults.string(forKey: "phrase-day-" + vault) == day }
    func finishGeneration(vault: String, day: String) { defaults.set(day, forKey: "phrase-day-" + vault) }
}
