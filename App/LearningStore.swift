import Foundation
import Observation

struct LearningSnapshot: Sendable {
    var state: LearningState
    var revision: String?
    var conflicted: Bool
}

@MainActor @Observable final class LearningStore {
    private(set) var state = LearningState()
    private(set) var blocked = true
    var error: String?
    private let writer = StudyFileWriter()
    private var url: URL?
    private var revision: String?
    private var epoch = UUID()
    private var tail: Task<Void, Never>?

    func close() { epoch = UUID(); url = nil; state = .init(); revision = nil; blocked = true; error = nil }
    func open(_ root: URL) async {
        close(); url = root.appendingPathComponent(".workspace/learning-state.json")
        await recover(acknowledge: false)
    }
    func recover(acknowledge: Bool = true) async {
        let request = epoch
        guard let url else { return }
        do {
            let snapshot = try await writer.loadLearning(url, recover: acknowledge)
            guard epoch == request else { return }
            state = snapshot.state; revision = snapshot.revision; blocked = snapshot.conflicted
            error = blocked ? StudyFileError.conflict.localizedDescription : nil
        } catch { if epoch == request { blocked = true; self.error = error.localizedDescription } }
    }
    func change(ifCurrent: @escaping @MainActor () -> Bool,
                _ edit: @escaping @MainActor (inout LearningState) throws -> Void) async throws {
        let request = epoch, previous = tail
        let task = Task { @MainActor [self] in
            await previous?.value
            guard epoch == request, ifCurrent(), !blocked, let url else { throw StudyImportError.staleVault }
            var next = state; try edit(&next); try next.validate()
            do {
                let saved = try await writer.writeLearning(next, to: url, expectedRevision: revision)
                guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
                state = next; revision = saved; error = nil
            } catch {
                if epoch == request {
                    self.error = error.localizedDescription
                    if error as? StudyFileError == .conflict { blocked = true }
                }
                throw error
            }
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
    func start(_ steps: [LearningStep], duration: DailyLessonDuration,
               ifCurrent: @escaping @MainActor () -> Bool) async throws {
        try await change(ifCurrent: ifCurrent) { state in
            guard state.session?.isComplete != false else { return }
            state.session = LearningSession(duration: duration, steps: steps)
            state.recentCardIDs = steps.map(\.card.id)
        }
    }
    func answer(sessionID: UUID, stepID: UUID, rating: FlashcardRating, response: String,
                skipped: Bool = false, now: Date = Date(), ifCurrent: @escaping @MainActor () -> Bool) async throws {
        try await change(ifCurrent: ifCurrent) { state in
            guard var session = state.session, session.id == sessionID else { throw DailyLessonError.staleStep }
            if session.answers.contains(where: { $0.stepID == stepID }) { return }
            guard let step = session.current, step.id == stepID else { throw DailyLessonError.staleStep }
            session.answers.append(.init(stepID: stepID, rating: rating, response: String(response.prefix(2000)), skipped: skipped))
            if !skipped {
                let ids = Set((step.sourceCards ?? [step.card]).map(\.id))
                state.evidence.removeAll { ids.contains($0.cardID) }
                state.evidence += ids.map { .init(cardID: $0, rating: rating, practicedAt: now) }
                state.evidence = Array(state.evidence.suffix(2000))
            }
            if session.answers.count == session.steps.count { session.completedAt = now }
            state.session = session
        }
    }
    func startCourse(_ module: CourseModule, checkpoint: Bool, duration: DailyLessonDuration,
                     modules: [CourseModule], ifCurrent: @escaping @MainActor () -> Bool) async throws {
        try await change(ifCurrent: ifCurrent) { state in
            guard state.courseSession?.isComplete != false else { return }
            let progress = state.course ?? CourseProgress()
            guard CourseCatalog.unlocked(module.id, modules: modules, progress: progress) else { throw StudyImportError.unavailable }
            let steps = CourseCatalog.steps(module, checkpoint: checkpoint, progress: progress, duration: duration)
            state.schemaVersion = 2
            state.courseSession = LearningSession(duration: checkpoint ? .long : duration, steps: steps,
                course: .init(moduleID: module.id, catalogVersion: CourseCatalog.version, checkpoint: checkpoint))
        }
    }
    func answerCourse(sessionID: UUID, stepID: UUID, rating: FlashcardRating, response: String,
                      now: Date = Date(), ifCurrent: @escaping @MainActor () -> Bool) async throws {
        try await change(ifCurrent: ifCurrent) { state in
            guard var session = state.courseSession, session.id == sessionID else { throw DailyLessonError.staleStep }
            if session.answers.contains(where: { $0.stepID == stepID }) { return }
            guard let step = session.current, step.id == stepID, let task = step.courseTask else { throw DailyLessonError.staleStep }
            let rating: FlashcardRating = session.failedStepIDs?.contains(stepID) == true ? .forgot : rating
            session.answers.append(.init(stepID: stepID, rating: rating, response: String(response.prefix(2000))))
            var progress = state.course ?? CourseProgress()
            if rating == .forgot { progress.mistakes.insert(task.itemID) }
            else if task.phase != .explanation && task.phase != .trace { progress.mistakes.remove(task.itemID) }
            if session.course?.checkpoint == false, rating == .remembered,
               task.phase == .recall || (task.phase == .production && task.glyph == nil) {
                progress.trained.insert(task.itemID)
            }
            if session.answers.count == session.steps.count {
                session.completedAt = now
                if let check = CourseCatalog.checkpoint(session, now: now) {
                    let failed = Set(session.answers.filter { $0.rating != .remembered }.compactMap { answer in
                        session.steps.first { $0.id == answer.stepID }?.courseTask?.itemID
                    })
                    progress.mistakes.formUnion(failed)
                    progress.checks.append(check); progress.checks = Array(progress.checks.suffix(512))
                    if check.passed {
                        var dates = progress.firstPassedAt ?? [:]
                        let first = dates[check.moduleID] ?? progress.checks.first { $0.moduleID == check.moduleID && $0.passed }?.date
                        if let first, !Calendar.current.isDate(first, inSameDayAs: now) {
                            var ids = progress.reinforcedIDs ?? []; ids.insert(check.moduleID); progress.reinforcedIDs = ids
                        }
                        dates[check.moduleID] = first ?? now; progress.firstPassedAt = dates
                        progress.completed.insert(check.moduleID)
                        progress.trained.formUnion(session.steps.compactMap { $0.courseTask?.itemID })
                    }
                }
            }
            state.course = progress; state.courseSession = session
        }
    }
    func flagCourseFailure(sessionID: UUID, stepID: UUID, ifCurrent: @escaping @MainActor () -> Bool) async throws {
        try await change(ifCurrent: ifCurrent) { state in
            guard var session = state.courseSession, session.id == sessionID, session.current?.id == stepID else { throw DailyLessonError.staleStep }
            var failed = session.failedStepIDs ?? []; failed.insert(stepID); session.failedStepIDs = failed
            state.courseSession = session
        }
    }
}
