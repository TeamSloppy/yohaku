import Foundation

struct LearningStep: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var card: Flashcard
    var mode: FlashcardExerciseMode
    var reason: String
    var sourceCards: [Flashcard]?
    var exercise: FlashcardExercise { .init(card: card, mode: mode) }
    func available(in cards: [Flashcard]) -> Bool {
        (sourceCards ?? [card]).allSatisfy { snapshot in
            cards.contains { $0.id == snapshot.id && StudyMaterialFields($0) == StudyMaterialFields(snapshot) && $0.handwriting == snapshot.handwriting }
        }
    }
}

struct LearningAnswer: Codable, Equatable, Sendable {
    var stepID: UUID
    var rating: FlashcardRating
    var response: String
    var skipped: Bool = false
}

struct LearningSession: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var duration: DailyLessonDuration
    var steps: [LearningStep]
    var answers: [LearningAnswer] = []
    var completedAt: Date?
    var current: LearningStep? { steps.dropFirst(answers.count).first }
    var isComplete: Bool { completedAt != nil }
    func validate() throws {
        guard !steps.isEmpty, steps.count <= duration.capacity,
              Set(steps.map(\.id)).count == steps.count,
              answers.map(\.stepID) == Array(steps.prefix(answers.count)).map(\.id),
              answers.count <= steps.count, (completedAt != nil) == (answers.count == steps.count),
              try StudyFileWriter.encode(self).count <= 8 * 1024 * 1024 else { throw DailyLessonError.invalidSnapshot }
    }
}

struct PracticeEvidence: Codable, Equatable, Sendable {
    var cardID: UUID
    var rating: FlashcardRating
    var practicedAt: Date
}

struct LearningState: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var session: LearningSession?
    var recentCardIDs: [UUID] = []
    var evidence: [PracticeEvidence] = []
    func validate() throws {
        guard schemaVersion == 1 else { throw StudyImportError.unavailable }
        try session?.validate()
        guard recentCardIDs.count <= 40, evidence.count <= 2000,
              Set(evidence.map(\.cardID)).count == evidence.count else { throw DailyLessonError.invalidSnapshot }
    }
    static func decode(_ data: Data?) throws -> Self {
        let value = try data.map { try JSONDecoder().decode(Self.self, from: $0) } ?? Self()
        try value.validate(); return value
    }
}

enum ExtraPracticePlanner {
    static func plan(cards: [Flashcard], materials: [StudyMaterialRecord], state: LearningState,
                     duration: DailyLessonDuration, now: Date = Date()) -> [LearningStep] {
        let eligible = DailyLessonPlanner.eligibleCards(cards, materials: materials, now: .distantFuture)
            .filter { $0.reviewCount > 0 && !$0.japanese.isEmpty && !$0.translation.isEmpty }
        let evidence = Dictionary(uniqueKeysWithValues: state.evidence.map { ($0.cardID, $0) })
        let recent = Set(state.recentCardIDs)
        func difficulty(_ card: Flashcard) -> Int {
            let rating = evidence[card.id]?.rating ?? card.lastRating
            return rating == .forgot ? 2 : rating == .hard ? 1 : 0
        }
        return eligible.sorted {
            if difficulty($0) != difficulty($1) { return difficulty($0) > difficulty($1) }
            if recent.contains($0.id) != recent.contains($1.id) { return !recent.contains($0.id) }
            let a = evidence[$0.id]?.practicedAt ?? $0.lastReviewAt ?? .distantPast
            let b = evidence[$1.id]?.practicedAt ?? $1.lastReviewAt ?? .distantPast
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }.prefix(duration.capacity).map { card in
            .init(card: card, mode: FlashcardPracticeQueue.exercise(for: card).mode,
                  reason: difficulty(card) > 0 ? "Закрепим сложное" : "Вспомним изученное")
        }
    }
}
