import Foundation
import Testing
import StudyIntelligence
@testable import Yohaku

struct PracticeGenerationTests {
    @Test func knownKanaDoesNotUnlockUnknownGrammarOrVocabulary() throws {
        let cards = [Flashcard(japanese: "大きい", reading: "おおきい", translation: "Большой", successfulReviews: 1),
                     Flashcard(japanese: "家", reading: "いえ", translation: "Дом", successfulReviews: 1)]
        let words = PracticeGeneration.words(cards)
        func json(_ particle: String, second: UUID? = nil) -> String {
            "[{\"wordIDs\":[\"\(words[0].id)\",\"\(second ?? words[1].id)\"],\"between\":[\"\(particle)\"],\"translation\":\"Большой дом\",\"alternatives\":[\"Маленький дом\",\"Дом большой\",\"Большой сад\"],\"explanation\":\"Пример\"}]"
        }
        #expect(try PhraseComposition.parse(json("の"), words: words, kana: ["の"], allowedParticles: []).isEmpty)
        #expect(try PhraseComposition.parse(json("", second: UUID()), words: words, kana: [], allowedParticles: []).isEmpty)
        let phrases = try PhraseComposition.parse(json(""), words: words, kana: [], allowedParticles: [])
        let steps = try PracticeGeneration.steps(phrases, cards: cards, kana: [])
        #expect(steps.count == 1)
        let reading = try #require(PracticeGeneration.reading(steps))
        #expect(reading.reading?.passage == phrases[0].japanese)
        #expect(reading.available(in: cards))
        #expect(reading.reading?.choices.contains(phrases[0].translation) == true)
        #expect(steps[0].available(in: cards))
        #expect(!steps[0].available(in: Array(cards.prefix(1))))
        var changed = cards; changed[0].translation = "Другой перевод"
        #expect(!steps[0].available(in: changed))
        #expect(PracticeGeneration.particles(cards).isEmpty)
        #expect(throws: (any Error).self) { try PhraseComposition.parse("broken", words: words, kana: []) }
    }
}
