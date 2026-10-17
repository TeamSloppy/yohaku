import Foundation
import Testing
@testable import Yohaku

struct DailyLessonPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func card(_ index: Int, reviewed: Bool = false) -> Flashcard {
        Flashcard(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!, japanese: "語\(index)",
                  translation: "слово\(index)", createdAt: now.addingTimeInterval(Double(index)), dueAt: now,
                  successfulReviews: reviewed ? 1 : 0)
    }
    private func plan(_ cards: [Flashcard], _ duration: DailyLessonDuration = .standard,
                      materials: [StudyMaterialRecord]? = nil) -> DailyLessonPlan {
        DailyLessonPlanner.plan(cards: cards, materials: materials, duration: duration, now: now, calendar: calendar)
    }

    @Test func durationsBoundMainRoundAndUnusedCards() {
        for duration in DailyLessonDuration.allCases {
            let reviews = (1...50).map { card($0, reviewed: true) }
            let unused = (51...60).map { card($0) }
            #expect(plan(reviews, duration).items.count == duration.capacity)
            #expect(plan(unused, duration).items.count == duration.newLimit)
            let mixed = plan(Array(reviews.prefix(2)) + unused, duration)
            #expect(mixed.items.prefix(2).allSatisfy { $0.exercise.card.reviewCount > 0 })
            #expect(mixed.items.filter { $0.exercise.card.reviewCount == 0 }.count == duration.newLimit)
        }
        #expect(plan([]).items.isEmpty)
        #expect(plan([card(1)]).items.count == 1)
    }

    @Test func dueBoundaryDifficultyStableTiesAndTruthfulReasons() {
        let regular = card(1, reviewed: true)
        var historical = card(2, reviewed: true); historical.failedReviews = 1; historical.lastRating = .remembered
        var hard = card(3, reviewed: true); hard.lastRating = .hard
        var forgot = card(4, reviewed: true); forgot.lastRating = .forgot
        var future = card(5, reviewed: true); future.dueAt = now.addingTimeInterval(0.001)
        let unused = card(6)
        let result = plan([future, unused, regular, historical, hard, forgot])
        #expect(result.items.map(\.id) == [forgot.id, hard.id, historical.id, regular.id, unused.id])
        #expect(result.items.map(\.reason) == ["Ошибка в прошлый раз", "Было сложно", "Пора повторить", "Пора повторить", "Новое выражение"])
        let ties = [card(9, reviewed: true), card(8, reviewed: true)]
        #expect(plan(ties).items.map(\.id) == plan(ties.reversed()).items.map(\.id))
        #expect(plan([regular, regular]).items.count == 1)
        #expect(plan([future]).items.isEmpty)
    }

    @Test func onlyAcknowledgedMaterialCardsJoinManualCards() {
        var linked = card(1)
        let manual = card(2)
        var record = StudyMaterialRecord(fields: StudyMaterialFields(linked), source: .init(vaultID: "v", documentID: UUID(),
            contentRevision: "r", path: "source.md", excerpt: "quote", quote: "quote"))
        linked.materialID = record.id
        #expect(plan([linked, manual], materials: [record]).items.map(\.id) == [manual.id])
        record.disposition = .accepted; record.cardID = UUID()
        #expect(plan([linked], materials: [record]).items.isEmpty)
        record.cardID = linked.id
        #expect(plan([linked, manual], materials: [record]).items.count == 2)
        record.freshness = .missing
        #expect(plan([linked], materials: [record]).items.count == 1)
        #expect(plan([linked, manual], materials: nil).items.map(\.id) == [manual.id])
        #expect(plan([linked], materials: []).items.isEmpty)
    }

    @Test @MainActor func switchingAndReopeningVaultBlocksTodayUntilStoresFinish() async throws {
        let writer = TodayOpeningWriter(), workspace = WorkspaceModel(writer: writer)
        let first = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let second = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        try await workspace.openVault(first, remember: false)
        #expect(await workspace.flashcards.add(card(1)))
        for target in [second, second] {
            let previous = workspace.dailyLessonContext
            await writer.pauseNextLoad()
            let opening = Task { try await workspace.openVault(target, remember: false) }
            await writer.waitUntilPaused()
            #expect(workspace.dailyLessonContext != previous)
            #expect(!workspace.dailyLessonVaultReady)
            await writer.resume()
            try await opening.value
            #expect(workspace.dailyLessonVaultReady)
            #expect(workspace.flashcards.cards.isEmpty)
        }
    }

    @Test @MainActor func staleRecoveryContextCannotReloadNewOrReopenedVault() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(); try await workspace.openVault(root, remember: false)
        let context = workspace.dailyLessonContext
        try await workspace.openVault(root, remember: false)
        workspace.flashcards.error = "new context"
        await workspace.recoverDailyLesson(context: context)
        #expect(workspace.flashcards.error == "new context")
    }

    @Test func calendarDayAndZoneAreDerivedFromInjectedClock() {
        let input = [card(1)]
        let before = plan(input)
        let tomorrow = DailyLessonPlanner.plan(cards: input, materials: nil, duration: .standard,
            now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)
        #expect(tomorrow.dayStart != before.dayStart)
        var shifted = calendar; shifted.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let otherZone = DailyLessonPlanner.plan(cards: input, materials: nil, duration: .standard, now: now, calendar: shifted)
        #expect(otherZone.timeZoneID != before.timeZoneID)
        #expect(otherZone.dayStart != before.dayStart)
    }
}

private actor TodayOpeningWriter: StudyFileWriting, StudyStateFileWriting {
    private let base: any StudyFileWriting & StudyStateFileWriting = StudyFileWriter()
    private var pause = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pauseNextLoad() { pause = true }
    func waitUntilPaused() async { if pending == nil { await withCheckedContinuation { observer = $0 } } }
    func resume() { pending?.resume(); pending = nil }
    func load(_ url: URL) async throws -> StudyFileSnapshot {
        if pause {
            pause = false
            await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil }
        }
        return try await base.load(url)
    }
    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) async throws -> String {
        try await base.write(cards, to: url, expectedRevision: expectedRevision)
    }
    func recover(_ url: URL) async throws -> StudyFileSnapshot { try await base.recover(url) }
    func loadState(_ url: URL) async throws -> StudyStateSnapshot { try await base.loadState(url) }
    func recoverState(_ url: URL) async throws -> StudyStateSnapshot { try await base.recoverState(url) }
    func writeState(_ state: StudyMaterialState, to url: URL, expectedRevision: String?) async throws -> String {
        try await base.writeState(state, to: url, expectedRevision: expectedRevision)
    }
}
