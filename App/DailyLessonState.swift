import Foundation

struct DailyLessonStep: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var card: Flashcard
    var mode: FlashcardExerciseMode
    var reason: String
    var source: StudyMaterialSource?
    var exercise: FlashcardExercise { .init(card: card, mode: mode) }
    func matches(_ current: Flashcard) -> Bool {
        StudyMaterialFields(card) == StudyMaterialFields(current) && card.handwriting == current.handwriting
    }
}

struct DailyLessonOutcome: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case reviewed, deleted, edited, unconfirmed }
    var stepID: UUID
    var kind: Kind
    var rating: FlashcardRating?
    var operationID: UUID?
}

struct DailyLessonState: Codable, Equatable, Identifiable, Sendable {
    static let maximumSteps = 40
    static let maximumBytes = 8 * 1024 * 1024
    var id = UUID()
    var startedAt: Date
    var duration: DailyLessonDuration
    var steps: [DailyLessonStep]
    var outcomes: [DailyLessonOutcome] = []
    var completedAt: Date?
    var current: DailyLessonStep? { outcomes.count < steps.count ? steps[outcomes.count] : nil }
    var isComplete: Bool { completedAt != nil }
    // Reserve every outcome before Start, using the same canonical encoder as disk writes.
    // 128 bytes cover any finite JSON date number beyond the representative completion date.
    func maximumProgressSize() throws -> Int {
        var completed = self
        completed.outcomes = steps.map { .init(stepID: $0.id, kind: .reviewed, rating: .remembered, operationID: UUID()) }
        completed.completedAt = .distantFuture
        return try StudyFileWriter.encode(completed).count + 128
    }
    func validate() throws {
        guard !steps.isEmpty, steps.count <= Self.maximumSteps, steps.count <= duration.capacity,
              steps.filter({ $0.card.successfulReviews == 0 && $0.card.failedReviews == 0 }).count <= duration.newLimit,
              Set(steps.map(\.id)).count == steps.count, Set(steps.map { $0.card.id }).count == steps.count,
              outcomes.count <= steps.count, (completedAt != nil) == (outcomes.count == steps.count),
              zip(outcomes, steps).allSatisfy({ $0.stepID == $1.id }),
              outcomes.allSatisfy({ $0.kind == .reviewed ? ($0.rating != nil && $0.operationID != nil) : ($0.rating == nil && $0.operationID == nil) }),
              try StudyFileWriter.encode(self).count <= Self.maximumBytes,
              try maximumProgressSize() <= Self.maximumBytes else { throw DailyLessonError.invalidSnapshot }
    }
}

struct DailyLessonCompletion: Codable, Equatable, Sendable {
    var lessonID: UUID
    var completedAt: Date
    var dayStart: Date
    var timeZoneID: String
    var reviewed: Int
    var skipped: Int
    func covers(_ now: Date, calendar: Calendar) -> Bool {
        (timeZoneID == calendar.timeZone.identifier && dayStart == calendar.startOfDay(for: now)) ||
            calendar.isDate(completedAt, inSameDayAs: now)
    }
}

struct DailyLessonReviewIntent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var lessonID: UUID
    var stepID: UUID
    var rating: FlashcardRating
    var reviewedCard: Flashcard
    var expectedCardRevision: String?
}

enum DailyLessonError: Error, LocalizedError {
    case invalidSnapshot, selectionChanged, alreadyCompleted, staleStep, ambiguous
    var errorDescription: String? {
        switch self {
        case .invalidSnapshot: "Занятие повреждено или превышает 40 карточек / 8 МиБ. Откройте библиотеку или выберите более короткое занятие."
        case .selectionChanged: "Подборка изменилась. Проверьте её и начните заново."
        case .alreadyCompleted: "Сегодняшнее занятие уже завершено."
        case .staleStep: "Шаг занятия уже изменился. Откройте сохранённый прогресс."
        case .ambiguous: "Нельзя подтвердить сохранение оценки. Продолжите без повторного применения этой оценки."
        }
    }
}
