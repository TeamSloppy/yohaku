import Foundation

enum CourseSkill: String, Codable, CaseIterable, Sendable { case reading, writing, usage }
enum CourseAnswer {
    static func matches(_ response: String, expected: String, reading: Bool) -> Bool {
        func normalized(_ value: String) -> String {
            let text = reading ? (value.applyingTransform(.hiraganaToKatakana, reverse: true) ?? value) : value
            return FlashcardAnswer.normalized(text.replacingOccurrences(of: "-", with: " "))
        }
        let answer = normalized(response), target = normalized(expected)
        let variants = ["shi":["si"], "chi":["ti"], "tsu":["tu"], "fu":["hu"], "ji":["zi"], "wo":["o"]]
        return answer == target || (reading && variants[target]?.contains(answer) == true)
    }
}
enum CoursePhase: String, Codable, Sendable { case explanation, trace, recall, recognition, production, reading }
struct CourseTask: Codable, Equatable, Sendable {
    var itemID: String
    var phase: CoursePhase
    var skill: CourseSkill
    var glyph: KanaGlyph?
    var readingAlternatives: [String]?
}
struct CourseAttempt: Codable, Equatable, Sendable {
    var moduleID: String
    var catalogVersion: Int
    var checkpoint: Bool
}
struct CourseCheckpoint: Codable, Equatable, Sendable {
    var moduleID: String
    var date: Date
    var scores: [CourseSkill: Double]
    var passed: Bool { !scores.isEmpty && scores.values.allSatisfy { $0 >= 0.8 } }
}
struct CourseProgress: Codable, Equatable, Sendable {
    var completed: Set<String> = []
    var trained: Set<String> = []
    var checks: [CourseCheckpoint] = []
    var mistakes: Set<String> = []
    var firstPassedAt: [String: Date]?
    var reinforcedIDs: Set<String>?
    func reinforced(_ module: String, calendar: Calendar = .current) -> Bool {
        if reinforcedIDs?.contains(module) == true { return true }
        let passes = checks.filter { $0.moduleID == module && $0.passed }.map(\.date)
        return Set(passes.map { calendar.startOfDay(for: $0) }).count > 1
    }
}
struct CourseItem: Identifiable, Sendable {
    var id: String
    var japanese: String
    var reading: String
    var meaning: String
    var glyph: KanaGlyph?
    var writingHint = ""
    var readingAlternatives: [String] = []
    var card: Flashcard {
        var card = Flashcard(japanese: japanese, reading: reading, translation: meaning)
        card.courseItemID = id; card.note = writingHint; return card
    }
}
struct CourseModule: Identifiable, Sendable {
    var id: String
    var title: String
    var stage: String
    var explanation: String
    var items: [CourseItem]
    var passage: String = ""
    var passageMeaning: String = ""
    var particles: Set<String> = []
}
enum CourseCatalog {
    static let version = 1
    static func load() throws -> [CourseModule] {
        let glyphs = try CourseTemplates.load()
        return try hiragana(glyphs) + katakana(glyphs) + [firstKanji(glyphs)] + n5(glyphs)
    }
    static func kanaModule(alphabet: KanaAlphabet, row: Int, glyphs: [KanaGlyph], words: [(String,String,String)]) -> CourseModule {
        let signs = glyphs.filter { $0.alphabet == alphabet && $0.row == row }
        let items = signs.map { CourseItem(id: "\(alphabet.rawValue).\($0.symbol)", japanese: $0.symbol, reading: $0.reading, meaning: "Звучание: " + $0.reading, glyph: $0) }
        return .init(id: "\(alphabet.rawValue).row.\(row)", title: signs.map(\.symbol).joined(separator: " "), stage: alphabet.title,
            explanation: "\(alphabet.title) передаёт звучание. Запомните чтение, обведите каждый знак и напишите его без образца. Ромадзи здесь служит подсказкой к звучанию. В проверке образец скрыт.",
            items: items + words.map { .init(id: "word:" + $0.0, japanese: $0.0, reading: $0.1, meaning: $0.2) })
    }
    static func unlocked(_ moduleID: String, modules: [CourseModule], progress: CourseProgress) -> Bool {
        guard let index = modules.firstIndex(where: { $0.id == moduleID }) else { return false }
        return modules.prefix(index).allSatisfy { progress.completed.contains($0.id) }
    }
    static func steps(_ module: CourseModule, checkpoint: Bool, progress: CourseProgress,
                      duration: DailyLessonDuration) -> [LearningStep] {
        func step(_ item: CourseItem, _ phase: CoursePhase, _ skill: CourseSkill) -> LearningStep {
            .init(card: item.card, mode: .recognition, reason: module.title,
                  courseTask: .init(itemID: item.id, phase: phase, skill: skill, glyph: item.glyph, readingAlternatives: item.readingAlternatives))
        }
        if checkpoint {
            return module.items.flatMap { item in
                [step(item, .recognition, .reading)] + (item.glyph == nil ? [step(item, .production, .usage)] : [step(item, .recall, .writing)])
            }.shuffled()
        }
        let symbols = module.items.filter { $0.glyph != nil }
        let fresh = Array(symbols.filter { !progress.trained.contains($0.id) || progress.mistakes.contains($0.id) }.prefix(duration.newLimit))
        var knownSymbols = Set(progress.trained.compactMap { $0.split(separator: ".").last.map(String.init) }).union(fresh.map(\.japanese))
        if progress.trained.contains("katakana.long") { knownSymbols.insert("ー") }
        let words = module.items.filter { $0.glyph == nil && (!progress.trained.contains($0.id) || progress.mistakes.contains($0.id)) &&
            (symbols.isEmpty || $0.japanese.allSatisfy { knownSymbols.contains(String($0)) }) }.prefix(duration.newLimit)
        var steps = Array(module.items.filter { progress.trained.contains($0.id) }.prefix(2)).map { step($0, .recognition, .reading) }
        steps += fresh.flatMap { [step($0, .explanation, .reading), step($0, .trace, .writing), step($0, .recall, .writing)] }
        steps += words.flatMap { [step($0, .explanation, .reading), step($0, .recognition, .reading), step($0, .production, .usage)] }
        let availableWords = module.items.filter { item in item.glyph == nil &&
            (progress.trained.contains(item.id) || words.contains(where: { $0.id == item.id })) }
        if !availableWords.isEmpty {
            var reading = step(availableWords[0], .reading, .reading)
            let known = progress.trained.union(fresh.map(\.id)).union(words.map(\.id))
            let fullText = !module.passage.isEmpty && module.items.allSatisfy { known.contains($0.id) }
            reading.card.japanese = fullText ? module.passage : availableWords.map(\.japanese).joined(separator: " · ")
            reading.card.translation = fullText ? module.passageMeaning : availableWords.map(\.meaning).joined(separator: " · ")
            steps.append(reading)
        }
        if steps.isEmpty { steps = module.items.map { step($0, .recognition, .reading) } }
        return Array(steps.prefix(duration.capacity))
    }
    static func checkpoint(_ session: LearningSession, now: Date) -> CourseCheckpoint? {
        guard let attempt = session.course, attempt.checkpoint, session.isComplete else { return nil }
        var scores: [CourseSkill: Double] = [:]
        for skill in CourseSkill.allCases {
            let steps = session.steps.filter { $0.courseTask?.skill == skill }
            guard !steps.isEmpty else { continue }
            let ids = Set(steps.map(\.id))
            scores[skill] = Double(session.answers.filter { ids.contains($0.stepID) && $0.rating == .remembered && !$0.skipped }.count) / Double(steps.count)
        }
        return .init(moduleID: attempt.moduleID, date: now, scores: scores)
    }
}
