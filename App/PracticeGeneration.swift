import Foundation
import StudyIntelligence

enum PracticeGeneration {
    static func words(_ cards: [Flashcard], trained: Set<String> = []) -> [PhraseWord] {
        var seen = Set<String>()
        return cards.filter {
            ($0.reviewCount > 0 || $0.courseItemID.map(trained.contains) == true) &&
            ($0.courseItemID == nil || $0.courseItemID!.hasPrefix("word:")) &&
            $0.phrasePractice == nil && !$0.japanese.isEmpty && !$0.translation.isEmpty &&
            $0.japanese.count <= 80 && $0.translation.count <= 240 && seen.insert($0.japanese).inserted
        }.prefix(24).map(PhrasePractice.word)
    }
    // Knowing a kana character is not evidence of knowing a grammatical particle.
    static func particles(_ cards: [Flashcard]) -> Set<String> {
        var result = Set<String>()
        for card in cards where card.reviewCount > 0 {
            guard let phrase = card.phrasePractice else { continue }
            var remaining = phrase.prompt
            for word in phrase.words { remaining = remaining.replacingOccurrences(of: word.japanese, with: "") }
            for particle in ["の", "は", "が", "と", "も", "に", "へ", "で", "を"] where remaining.contains(particle) { result.insert(particle) }
        }
        return result
    }
    static func steps(_ phrases: [ComposedPhrase], cards: [Flashcard], kana: Set<String>) throws -> [LearningStep] {
        let vocabulary = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        return try phrases.map { phrase in
            let sources = try phrase.words.map { word in
                guard let card = vocabulary[word.id], PhrasePractice.word(card) == word else { throw DailyLessonError.selectionChanged }
                return card
            }
            return LearningStep(card: PhrasePractice.card(phrase, kana: kana, now: Date()), mode: .recognition,
                                reason: "Составлено ИИ из изученных слов", sourceCards: sources)
        }
    }
    static func reading(_ steps: [LearningStep]) -> LearningStep? {
        let phrases = steps.filter { $0.card.phrasePractice != nil }
        guard let first = phrases.first, let phrase = first.card.phrasePractice else { return nil }
        var reading = first
        reading.id = UUID(); reading.reason = "Короткое чтение из знакомых слов"
        reading.reading = .init(passage: phrases.prefix(3).map(\.card.japanese).joined(separator: "\n"),
                                question: "Что означает первая строка?", answer: phrase.answer, choices: phrase.choices)
        var ids = Set<UUID>()
        reading.sourceCards = phrases.flatMap { $0.sourceCards ?? [] }.filter { ids.insert($0.id).inserted }
        return reading
    }
}
