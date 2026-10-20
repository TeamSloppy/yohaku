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
                state.evidence.removeAll { $0.cardID == step.card.id }
                state.evidence.append(.init(cardID: step.card.id, rating: rating, practicedAt: now))
                state.evidence = Array(state.evidence.suffix(2000))
            }
            if session.answers.count == session.steps.count { session.completedAt = now }
            state.session = session
        }
    }
}
