import Foundation

extension StudyMaterialStore {
    var lesson: DailyLessonState? { state.lesson }
    var canSkipUnconfirmedLesson: Bool { !storageBlocked && state.lessonIntent != nil }
    func completedLesson(on now: Date = Date(), calendar: Calendar = .current) -> DailyLessonCompletion? {
        state.completions.sorted { $0.completedAt > $1.completedAt }.first { $0.covers(now, calendar: calendar) }
    }

    @discardableResult func startLesson(_ plan: DailyLessonPlan, duration: DailyLessonDuration, cards: FlashcardStore,
                                        now: Date = Date(), calendar: Calendar = .current,
                                        ifCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> DailyLessonState {
        let request = lessonEpoch
        do {
            return try await serial { [self] in
                try writable(); guard ifCurrent() else { throw StudyImportError.staleVault }
                if let lesson = state.lesson, !lesson.isComplete { return lesson }
                guard completedLesson(on: now, calendar: calendar) == nil else { throw DailyLessonError.alreadyCompleted }
                let steps = try plan.items.map { item in
                    let record = state.records.first { $0.id == item.exercise.card.materialID && $0.cardID == item.id && $0.disposition == .accepted }
                    guard item.exercise.card.materialID == nil || record != nil else { throw DailyLessonError.selectionChanged }
                    return DailyLessonStep(card: item.exercise.card, mode: item.exercise.mode, reason: item.reason, source: record?.source)
                }
                let lesson = DailyLessonState(startedAt: now, duration: duration, steps: steps)
                try lesson.validate()
                return try await cards.captureLesson(plan.exercises, now: now, ifCurrent: ifCurrent) { [self] in
                    try checkLessonEpoch(request); guard ifCurrent() else { throw StudyImportError.staleVault }
                    var next = state; next.lesson = lesson
                    try await commit(next, request: request)
                    guard ifCurrent() else { throw StudyImportError.staleVault }
                    return lesson
                }
            }
        } catch { fail(error, request: request); throw error }
    }

    @discardableResult func submitLessonStep(lessonID: UUID, stepID: UUID, rating: FlashcardRating, cards: FlashcardStore,
                                             clock: @escaping @MainActor () -> Date = { Date() },
                                             calendar: @escaping @MainActor () -> Calendar = { .current },
                                             ifCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> DailyLessonState {
        let request = lessonEpoch
        do {
            return try await serial { [self] in
                try writable(); guard ifCurrent() else { throw StudyImportError.staleVault }
                guard let lesson = state.lesson, lesson.id == lessonID else { throw DailyLessonError.staleStep }
                if lesson.outcomes.contains(where: { $0.stepID == stepID }) { return lesson }
                guard let step = lesson.current, step.id == stepID else { throw DailyLessonError.staleStep }
                let outcome = try await cards.reviewLesson(step, lessonID: lessonID, rating: rating, now: clock(), calendar: calendar(), dependency: lessonDependency(), ifCurrent: ifCurrent) { [self] intent in
                    try checkLessonEpoch(request); guard ifCurrent() else { throw StudyImportError.staleVault }
                    var next = state; next.lessonIntent = intent
                    try await commit(next, request: request)
                    guard ifCurrent() else { throw StudyImportError.staleVault }
                    return try lessonDependency()
                }
                try checkLessonEpoch(request); guard ifCurrent() else { throw StudyImportError.staleVault }
                try await acknowledgeLesson(outcome, request: request, now: clock(), calendar: calendar())
                return state.lesson!
            }
        } catch { fail(error, request: request); throw error }
    }

    /// Safe explicit resolution: this never writes or re-applies a card grade.
    func skipUnconfirmedLesson(lessonID: UUID, stepID: UUID, cards: FlashcardStore,
                               clock: @escaping @MainActor () -> Date = { Date() },
                               calendar: @escaping @MainActor () -> Calendar = { .current },
                               ifCurrent: @escaping @MainActor () -> Bool = { true }) async throws {
        let request = lessonEpoch
        do {
            try await serial { [self] in
                try checkLessonEpoch(request)
                guard ifCurrent(), canSkipUnconfirmedLesson, let intent = state.lessonIntent,
                      intent.lessonID == lessonID, intent.stepID == stepID else { throw StudyImportError.unavailable }
                try await cards.verifyLessonCheckpoint(dependency: lessonDependency(), ifCurrent: ifCurrent)
                try checkLessonEpoch(request); guard ifCurrent() else { throw StudyImportError.staleVault }
                try await acknowledgeLesson(.init(stepID: stepID, kind: .unconfirmed), request: request, now: clock(), calendar: calendar())
            }
        } catch { fail(error, request: request); throw error }
    }

    func replayLesson(cards: FlashcardStore, request: UUID) async throws {
        guard let intent = state.lessonIntent else { return }
        let outcome = try await cards.recoverLessonReview(intent, dependency: lessonDependency())
        try checkLessonEpoch(request)
        try await acknowledgeLesson(outcome, request: request, now: Date(), calendar: .current)
    }

    private func acknowledgeLesson(_ outcome: DailyLessonOutcome, request: UUID, now: Date, calendar: Calendar) async throws {
        var next = state
        guard var lesson = next.lesson, lesson.current?.id == outcome.stepID else { throw DailyLessonError.staleStep }
        if let intent = next.lessonIntent {
            guard intent.lessonID == lesson.id, intent.stepID == outcome.stepID,
                  outcome.operationID == nil || outcome.operationID == intent.id else { throw DailyLessonError.staleStep }
        }
        lesson.outcomes.append(outcome); next.lessonIntent = nil
        if lesson.outcomes.count == lesson.steps.count {
            lesson.completedAt = now
            next.completions.append(.init(lessonID: lesson.id, completedAt: now, dayStart: calendar.startOfDay(for: now),
                timeZoneID: calendar.timeZone.identifier, reviewed: lesson.outcomes.filter { $0.kind == .reviewed }.count,
                skipped: lesson.outcomes.filter { $0.kind != .reviewed }.count))
            let sorted = next.completions.sorted { $0.completedAt > $1.completedAt }
            let protected = sorted.filter { $0.lessonID == sorted.first?.lessonID || $0.covers(now, calendar: calendar) }
            guard protected.count <= 32 else { throw DailyLessonError.invalidSnapshot }
            next.completions = protected + sorted.filter { value in !protected.contains { $0.lessonID == value.lessonID } }.prefix(32 - protected.count)
        }
        next.lesson = lesson
        try await commit(next, request: request)
    }
}
