import Foundation

enum DailyLessonDuration: Int, CaseIterable, Identifiable, Codable, Sendable {
    case short = 3, standard = 10, long = 20
    var id: Int { rawValue }
    var capacity: Int { rawValue * 2 }
    var newLimit: Int { switch self { case .short: 1; case .standard: 3; case .long: 5 } }
}

struct DailyLessonItem: Identifiable, Equatable {
    let exercise: FlashcardExercise
    let reason: String
    var id: UUID { exercise.id }
}

struct DailyLessonPlan: Equatable {
    var items: [DailyLessonItem] = []
    var dayStart = Date.distantPast
    var timeZoneID = ""
    var exercises: [FlashcardExercise] { items.map(\.exercise) }
}

enum DailyLessonPlanner {
    static func eligibleCards(_ cards: [Flashcard], materials: [StudyMaterialRecord]?, now: Date) -> [Flashcard] {
        var seen = Set<UUID>()
        return cards.filter { card in
            guard card.dueAt <= now, seen.insert(card.id).inserted else { return false }
            guard let materialID = card.materialID else { return true }
            return materials?.contains { $0.id == materialID && $0.disposition == .accepted && $0.cardID == card.id } == true
        }
    }

    static func plan(cards: [Flashcard], materials: [StudyMaterialRecord]?, duration: DailyLessonDuration,
                     now: Date, calendar: Calendar) -> DailyLessonPlan {
        let eligible = eligibleCards(cards, materials: materials, now: now)
        let reviews = eligible.filter { $0.reviewCount > 0 }.sorted {
            let lhs = FlashcardPracticeQueue.priority(of: $0, now: now)
            let rhs = FlashcardPracticeQueue.priority(of: $1, now: now)
            if lhs != rhs { return lhs > rhs }
            if $0.dueAt != $1.dueAt { return $0.dueAt < $1.dueAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let unused = eligible.filter { $0.reviewCount == 0 }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        let selected = Array(reviews.prefix(duration.capacity))
        let slots = min(duration.newLimit, max(0, duration.capacity - selected.count))
        let phrases = unused.filter { $0.phrasePractice?.question(for: $0) != nil }.prefix(min(2, slots))
        let words = unused.filter { $0.phrasePractice?.question(for: $0) == nil }.prefix(max(0, slots - phrases.count))
        return DailyLessonPlan(items: (selected + phrases + words).map { card in
            let reason = card.phrasePractice?.question(for: card) != nil ? "Фраза из знакомых слов" : card.reviewCount == 0 ? "Новое выражение" :
                card.lastRating == .forgot ? "Ошибка в прошлый раз" :
                card.lastRating == .hard ? "Было сложно" : "Пора повторить"
            return DailyLessonItem(exercise: FlashcardPracticeQueue.exercise(for: card), reason: reason)
        }, dayStart: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier)
    }

    /// Resolve only supplied IDs against current eligible contents; never refill or shuffle.
    static func resolve(_ exercises: [FlashcardExercise], cards: [Flashcard],
                        materials: [StudyMaterialRecord]?, now: Date) -> [FlashcardExercise] {
        let current = Dictionary(uniqueKeysWithValues: eligibleCards(cards, materials: materials, now: now).map { ($0.id, $0) })
        var seen = Set<UUID>()
        return exercises.compactMap { exercise in
            guard let card = current[exercise.id], seen.insert(exercise.id).inserted else { return nil }
            return FlashcardExercise(card: card, mode: exercise.mode)
        }
    }
}
