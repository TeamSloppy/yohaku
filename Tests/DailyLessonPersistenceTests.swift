import Foundation
import StudyCore
import Testing
@testable import Yohaku

@MainActor struct DailyLessonPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }
    private func root() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func card(_ word: String = "猫") -> Flashcard {
        Flashcard(japanese: word, reading: "ねこ", translation: "кошка", example: "猫です。", dueAt: now)
    }
    private func start(_ store: StudyMaterialStore, _ cards: FlashcardStore) async throws -> DailyLessonState {
        try await store.startLesson(DailyLessonPlanner.plan(cards: cards.cards, materials: store.records,
            duration: .standard, now: now, calendar: calendar), duration: .standard, cards: cards, now: now, calendar: calendar)
    }
    private func submit(_ store: StudyMaterialStore, _ cards: FlashcardStore, _ lesson: DailyLessonState) async throws -> DailyLessonState {
        let date = now, zone = calendar
        return try await store.submitLessonStep(lessonID: lesson.id, stepID: lesson.current!.id, rating: .remembered,
            cards: cards, clock: { date }, calendar: { zone })
    }

    @Test func versionOneMigratesWithoutRewritingAndFutureBytesSurvive() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), url = root.appendingPathComponent(".workspace/study-state.json")
        let record = StudyMaterialRecord(fields: .init(card()), source: .init(vaultID: "vault", documentID: UUID(),
            contentRevision: "revision", path: "source.md", excerpt: "猫", quote: "猫"))
        let original = StudyMaterialState(records: [record], intents: [.init(materialID: record.id, card: card(), expectedCardRevision: nil, createsCard: true)])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        json["schemaVersion"] = 1; json.removeValue(forKey: "completions")
        let bytes = try JSONSerialization.data(withJSONObject: json)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url)
        let loaded = try await writer.loadState(url)
        #expect(loaded.state == original); #expect(loaded.state.schemaVersion == 2)
        #expect(try Data(contentsOf: url) == bytes)
        _ = try await writer.writeState(loaded.state, to: url, expectedRevision: loaded.revision)
        let migrated = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(migrated["schemaVersion"] as? Int == 2)
        let cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        let future = Data(#"{"schemaVersion":99,"records":[],"intents":[]}"#.utf8)
        try future.write(to: url); await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(store.isBlocked)
        await #expect(throws: Error.self) { _ = try await start(store, cards) }
        await #expect(throws: Error.self) { try await store.skipUnconfirmedLesson(lessonID: UUID(), stepID: UUID(), cards: cards) }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test func malformedCompletionCountsRejectWithoutOverflow() throws {
        let invalid = StudyMaterialState(completions: [.init(lessonID: UUID(), completedAt: now,
            dayStart: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier,
            reviewed: Int.max, skipped: Int.max)])
        #expect(throws: Error.self) { _ = try StudyMaterialState.decode(StudyFileWriter.encode(invalid)) }
    }

    @Test func snapshotIsFrozenAndCapsFailBeforeCreatingLesson() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        var original = card(); original.handwriting = .init(japanese: Data([1, 2, 3]))
        #expect(await cards.add(original)); let lesson = try await start(store, cards)
        var changed = original; changed.example = "edited"; #expect(await cards.update(changed))
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        #expect(reopened.lesson == lesson)
        let tomorrow = now.addingTimeInterval(86_400)
        let continued = try await reopened.startLesson(.init(), duration: .short, cards: cards, now: tomorrow)
        #expect(continued == lesson)
        var huge = lesson; huge.steps[0].card.handwriting = .init(japanese: Data(repeating: 1, count: DailyLessonState.maximumBytes))
        #expect(throws: Error.self) { try huge.validate() }
        var many = lesson; many.steps = (0..<41).map { index in .init(card: card("語\(index)"), mode: .cloze, reason: "due") }
        #expect(throws: Error.self) { try many.validate() }
        var invalid = lesson; invalid.steps.append(invalid.steps[0])
        #expect(throws: Error.self) { try invalid.validate() }
        let url = root.appendingPathComponent(".workspace/study-state.json")
        let bytes = try Data(contentsOf: url)
        await #expect(throws: Error.self) { _ = try await writer.writeState(.init(lesson: huge), to: url, expectedRevision: nil) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test(arguments: [false, true]) func startRejectsDurationAndNewCardCapWithoutPartialState(tooManyNew: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let values = (0..<(tooManyNew ? 2 : 7)).map { index in
            var value = card("語\(index)"); value.successfulReviews = tooManyNew ? 0 : 1; return value
        }
        #expect(await cards.add(values))
        let plan = DailyLessonPlan(items: values.map { .init(exercise: .init(card: $0, mode: .recognition), reason: "reason") })
        await #expect(throws: Error.self) { _ = try await store.startLesson(plan, duration: .short, cards: cards, now: now, calendar: calendar) }
        #expect(store.lesson == nil); #expect(store.state.lessonIntent == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".workspace/study-state.json").path))
    }

    @Test func nearCapStartReservesProgressAndCanReplayAfterCardCommit() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        var original = card()
        let probe = DailyLessonState(startedAt: now, duration: .standard,
            steps: [.init(card: original, mode: .recognition, reason: "Новое выражение")])
        let room = DailyLessonState.maximumBytes - (try probe.maximumProgressSize())
        original.note = String(repeating: "x", count: room + 1)
        #expect(await cards.add(original))
        await #expect(throws: Error.self) { _ = try await start(store, cards) }
        #expect(store.lesson == nil); #expect(store.state.lessonIntent == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".workspace/study-state.json").path))
        original.note.removeLast(); #expect(await cards.update(original))
        let lesson = try await start(store, cards)
        #expect(try lesson.maximumProgressSize() == DailyLessonState.maximumBytes)
        await writer.failState(3)
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        let reopenedCards = FlashcardStore(writer: writer), reopened = StudyMaterialStore(writer: writer)
        await reopenedCards.open(vaultRoot: root); await reopened.open(vaultRoot: root, cards: reopenedCards)
        #expect(reopened.lesson?.isComplete == true); #expect(!reopened.isBlocked)
        #expect(reopenedCards.cards[0].reviewCount == 1)
        #expect(try StudyFileWriter.encode(reopened.lesson!).count <= DailyLessonState.maximumBytes)
    }

    @Test func gradeUsesCommittedScheduleAndDuplicateCallbackDoesNotReviewAgain() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original)); let lesson = try await start(store, cards)
        #expect(await cards.review(id: original.id, rating: .hard, now: now))
        let committed = cards.cards[0]
        let finished = try await submit(store, cards, lesson)
        let expected = FlashcardScheduler.review(committed, rating: .remembered, now: now, calendar: calendar)
        #expect(cards.cards[0].intervalDays == expected.intervalDays); #expect(cards.cards[0].reviewCount == 2)
        _ = try await submit(store, cards, lesson)
        #expect(cards.cards[0].reviewCount == 2); #expect(store.lesson == finished)
        #expect(finished.outcomes.count == 1); #expect(finished.isComplete)
        #expect(store.completedLesson(on: now, calendar: calendar)?.lessonID == lesson.id)
        await #expect(throws: Error.self) { _ = try await start(store, cards) }
    }

    @Test(arguments: [false, true]) func crashRecoveryAcknowledgesReceiptOrRequiresExplicitUnconfirmedSkip(afterCard: Bool) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original)); let lesson = try await start(store, cards)
        if afterCard { await writer.failState(3) } else { await writer.failNextReview() }
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        #expect(store.lesson?.outcomes.isEmpty == true); #expect(store.state.lessonIntent != nil)
        if afterCard {
            var staleDraft = original; staleDraft.note = "later edit"
            #expect(await cards.update(staleDraft)); #expect(cards.cards[0].appliedLessonOperationID != nil)
            #expect(await cards.review(id: original.id, rating: .hard, now: now))
        }
        let persistedCards = cards.cards
        let reopenedCards = FlashcardStore(writer: writer), reopened = StudyMaterialStore(writer: writer)
        await reopenedCards.open(vaultRoot: root); await reopened.open(vaultRoot: root, cards: reopenedCards)
        #expect(reopenedCards.cards == persistedCards)
        if afterCard {
            #expect(reopened.lesson?.isComplete == true); #expect(!reopened.isBlocked)
            #expect(reopened.lesson?.outcomes.first?.kind == .reviewed)
            #expect(reopenedCards.cards[0].note == "later edit"); #expect(reopenedCards.cards[0].reviewCount == 2)
        } else {
            #expect(reopened.isBlocked); #expect(reopened.canSkipUnconfirmedLesson)
            try await reopened.skipUnconfirmedLesson(lessonID: lesson.id, stepID: lesson.current!.id, cards: reopenedCards, clock: { now }, calendar: { calendar })
            #expect(reopened.lesson?.outcomes.first?.kind == .unconfirmed)
            #expect(reopenedCards.cards == [original]); #expect(!reopened.isBlocked)
        }
    }

    @Test func rawByteRollbackCannotCauseAnAutomaticSecondGrade() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(await cards.add(card())); let lesson = try await start(store, cards)
        let url = root.appendingPathComponent(".workspace/flashcards.json"), before = try Data(contentsOf: url)
        await writer.failState(3)
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        #expect(cards.cards[0].reviewCount == 1)
        try before.write(to: url, options: .atomic)
        let reopenedCards = FlashcardStore(writer: writer), reopened = StudyMaterialStore(writer: writer)
        await reopenedCards.open(vaultRoot: root); await reopened.open(vaultRoot: root, cards: reopenedCards)
        #expect(reopened.canSkipUnconfirmedLesson); #expect(reopened.lesson?.outcomes.isEmpty == true)
        #expect(try Data(contentsOf: url) == before); #expect(reopenedCards.cards[0].reviewCount == 0)
    }

    @Test(arguments: [0, 1, 2]) func missingEditedAndInkChangedTargetsSkipWithoutReview(kind: Int) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original)); let lesson = try await start(store, cards)
        if kind == 0 { #expect(await cards.delete(id: original.id)) }
        else {
            var draft = original
            if kind == 1 { draft.japanese += " " } else { draft.handwriting = .init(japanese: Data([4])) }
            #expect(await cards.update(draft))
        }
        let before = cards.cards; _ = try await submit(store, cards, lesson)
        #expect(cards.cards == before); #expect(store.lesson?.outcomes.first?.kind == (kind == 0 ? .deleted : .edited))
        #expect(store.lesson?.isComplete == true)
    }

    @Test func intentFailureDoesNotChangeCursorOrCardAndDeletedPendingNeverResurrects() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original)); let lesson = try await start(store, cards)
        await writer.failState(2)
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        #expect(cards.cards == [original]); #expect(store.state.lessonIntent == nil); #expect(store.lesson == lesson)
        await writer.failNextReview()
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        #expect(await cards.delete(id: original.id))
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        #expect(cards.cards.isEmpty); #expect(reopened.lesson?.outcomes.first?.kind == .deleted)
    }

    @Test(arguments: [0, 1, 2, 3]) func dependentWriterRejectsChangedStateCardsAndMarker(variant: Int) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(await cards.add(card())); let lesson = try await start(store, cards)
        await writer.alterDependency(variant)
        await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        #expect(store.lesson?.outcomes.isEmpty == true); #expect(cards.cards[0].reviewCount == 0)
        if variant == 0 {
            let url = root.appendingPathComponent(".workspace/study-state.json"), bytes = try Data(contentsOf: url)
            await #expect(throws: Error.self) { try await store.skipUnconfirmedLesson(lessonID: lesson.id, stepID: lesson.current!.id, cards: cards) }
            #expect(try Data(contentsOf: url) == bytes)
        }
    }

    @Test(arguments: 0..<8) func skipCheckpointsRejectExternalCardsOrConflictMarker(variant: Int) async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original)); let lesson = try await start(store, cards)
        let path = variant / 2
        if path >= 2 {
            await writer.failNextReview()
            await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) }
        }
        if path == 0 || path == 2 { #expect(await cards.delete(id: original.id)) }
        if path == 1 { var edited = original; edited.note += " edited"; #expect(await cards.update(edited)) }
        if path == 3 { await store.recover(cards: cards); #expect(store.canSkipUnconfirmedLesson) }
        let cardURL = root.appendingPathComponent(".workspace/flashcards.json")
        let stateURL = root.appendingPathComponent(".workspace/study-state.json"), before = try Data(contentsOf: stateURL)
        if variant % 2 == 0 {
            try Data("external conflict".utf8).write(to: root.appendingPathComponent(".workspace/flashcards-conflict.json"))
        } else { try JSONEncoder().encode([Flashcard(japanese: "外部", translation: "external")]).write(to: cardURL, options: .atomic) }
        let authoritative = try Data(contentsOf: cardURL)
        if path == 2 { await store.recover(cards: cards); #expect(store.isBlocked) }
        else if path == 3 {
            await #expect(throws: Error.self) { try await store.skipUnconfirmedLesson(lessonID: lesson.id,
                stepID: lesson.current!.id, cards: cards) }
        } else { await #expect(throws: Error.self) { _ = try await submit(store, cards, lesson) } }
        #expect(store.lesson?.outcomes.isEmpty == true); #expect(cards.isBlocked)
        #expect(try Data(contentsOf: cardURL) == authoritative); #expect(try Data(contentsOf: stateURL) == before)
        if path >= 2 { #expect(store.state.lessonIntent != nil) }
    }

    @Test func acceptedProvenanceAndClozeSnapshotSurviveSourceRemapAndDeletion() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let record = StudyMaterialRecord(fields: .init(card()), source: .init(vaultID: "vault", documentID: UUID(),
            contentRevision: "revision", path: "source.md", pageID: UUID(), region: .init(x: 1, y: 2, width: 3, height: 4),
            excerpt: "original excerpt", quote: "original quote", origin: .confirmedTranscription))
        _ = try await store.save([record], ifCurrent: { true }); #expect(await store.accept(record.id, cards: cards, validate: { _ in }))
        let plan = DailyLessonPlan(items: [.init(exercise: .init(card: cards.cards[0], mode: .cloze), reason: "reason")],
            dayStart: calendar.startOfDay(for: now), timeZoneID: calendar.timeZone.identifier)
        let lesson = try await store.startLesson(plan, duration: .standard, cards: cards, now: Date(), calendar: calendar)
        #expect(lesson.steps[0].source == record.source); #expect(lesson.steps[0].mode == .cloze)
        #expect(await store.remap("source.md", to: "moved.md")); await store.refreshSources { _ in .missing }
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        #expect(reopened.lesson == lesson); _ = try await submit(reopened, cards, lesson)
        #expect(cards.cards[0].reviewCount == 1)
    }

    @Test func queuedStartRevalidatesCommittedCardAndContextBeforePersisting() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        let original = card(); #expect(await cards.add(original))
        let plan = DailyLessonPlanner.plan(cards: cards.cards, materials: [], duration: .standard, now: now, calendar: calendar)
        await writer.pauseNextWrite()
        var changed = original; changed.translation += " changed"
        let editing = Task { await cards.update(changed) }; await writer.waitUntilPaused()
        let starting = Task { try await store.startLesson(plan, duration: .standard, cards: cards, now: now, calendar: calendar) }
        await Task.yield(); await writer.resume(); #expect(await editing.value)
        await #expect(throws: Error.self) { _ = try await starting.value }; #expect(store.lesson == nil)
        let currentPlan = DailyLessonPlanner.plan(cards: cards.cards, materials: [], duration: .standard, now: now, calendar: calendar)
        await writer.pauseNextWrite(); var current = true
        let stale = Task { try await store.startLesson(currentPlan, duration: .standard, cards: cards, now: now, calendar: calendar, ifCurrent: { current }) }
        await writer.waitUntilPaused(); current = false; await writer.resume()
        await #expect(throws: Error.self) { _ = try await stale.value }; #expect(store.lesson == nil)
    }

    @Test func staleGradeAndSameVaultReopenCannotPublishOldCursor() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = LessonControlledWriter(), cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(await cards.add(card())); let lesson = try await start(store, cards)
        await writer.pauseNextReview(); var current = true
        let grading = Task { try await store.submitLessonStep(lessonID: lesson.id, stepID: lesson.current!.id,
            rating: .remembered, cards: cards, ifCurrent: { current }) }
        await writer.waitUntilPaused(); current = false; store.close()
        await writer.resume(); await #expect(throws: Error.self) { _ = try await grading.value }
        #expect(store.lesson == nil)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(store.lesson?.id == lesson.id); #expect(store.lesson?.isComplete == true)
        #expect(cards.cards[0].reviewCount == 1)
    }

    @Test func completionUsesActualCompletionDayAndHistoryRemainsBounded() async throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let writer = StudyFileWriter(), url = root.appendingPathComponent(".workspace/study-state.json")
        let old = (1...32).map { index in DailyLessonCompletion(lessonID: UUID(), completedAt: now.addingTimeInterval(Double(-index) * 86_400),
            dayStart: calendar.startOfDay(for: now.addingTimeInterval(Double(-index) * 86_400)), timeZoneID: calendar.timeZone.identifier, reviewed: 1, skipped: 0) }
        _ = try await writer.writeState(.init(completions: old), to: url, expectedRevision: nil)
        let cards = FlashcardStore(writer: writer), store = StudyMaterialStore(writer: writer)
        await cards.open(vaultRoot: root); await store.open(vaultRoot: root, cards: cards)
        #expect(await cards.add(card())); let lesson = try await start(store, cards)
        let nextDay = now.addingTimeInterval(86_400), zone = calendar
        _ = try await store.submitLessonStep(lessonID: lesson.id, stepID: lesson.current!.id, rating: .remembered,
            cards: cards, clock: { nextDay }, calendar: { zone })
        #expect(store.lesson?.completedAt == nextDay); #expect(store.state.completions.count == 32)
        #expect(store.completedLesson(on: nextDay, calendar: calendar)?.lessonID == lesson.id)
        var shifted = calendar; shifted.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        #expect(store.completedLesson(on: nextDay, calendar: shifted)?.lessonID == lesson.id)
        let reopened = StudyMaterialStore(writer: writer); await reopened.open(vaultRoot: root, cards: cards)
        #expect(reopened.lesson == store.lesson); #expect(reopened.state.completions == store.state.completions)
    }
}

private actor LessonControlledWriter: StudyFileWriting, StudyStateFileWriting {
    private let base: any StudyFileWriting & StudyStateFileWriting = StudyFileWriter()
    private var stateWrites = 0
    private var failAt = 0
    private var failReview = false
    private var alteration: Int?
    private var pauseWrite = false
    private var pauseReview = false
    private var pending: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?
    func pauseNextWrite() { pauseWrite = true }
    func pauseNextReview() { pauseReview = true }
    func waitUntilPaused() async { if pending == nil { await withCheckedContinuation { observer = $0 } } }
    func resume() { pending?.resume(); pending = nil }
    private func wait() async { await withCheckedContinuation { pending = $0; observer?.resume(); observer = nil } }
    func failState(_ number: Int) { failAt = number }
    func failNextReview() { failReview = true }
    func alterDependency(_ variant: Int) { alteration = variant }
    func load(_ url: URL) async throws -> StudyFileSnapshot { try await base.load(url) }
    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) async throws -> String {
        if pauseWrite { pauseWrite = false; await wait() }
        return try await base.write(cards, to: url, expectedRevision: expectedRevision)
    }
    func recover(_ url: URL) async throws -> StudyFileSnapshot { try await base.recover(url) }
    func loadState(_ url: URL) async throws -> StudyStateSnapshot { try await base.loadState(url) }
    func recoverState(_ url: URL) async throws -> StudyStateSnapshot { try await base.recoverState(url) }
    func writeState(_ state: StudyMaterialState, to url: URL, expectedRevision: String?) async throws -> String {
        stateWrites += 1
        if stateWrites == failAt { throw CocoaError(.fileWriteNoPermission) }
        return try await base.writeState(state, to: url, expectedRevision: expectedRevision)
    }
    func writeImportedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?, intent: StudyAcceptanceIntent, dependency: StudyStateDependency) async throws -> String {
        try await base.writeImportedCards(cards, to: url, expectedRevision: expectedRevision, intent: intent, dependency: dependency)
    }
    func verifyLessonCards(_ cards: [Flashcard], at url: URL, expectedRevision: String?, dependency: StudyStateDependency) async throws {
        try await base.verifyLessonCards(cards, at: url, expectedRevision: expectedRevision, dependency: dependency)
    }
    func writeReviewedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?, intent: DailyLessonReviewIntent, dependency: StudyStateDependency) async throws -> String {
        if pauseReview { pauseReview = false; await wait() }
        if failReview { failReview = false; throw CocoaError(.fileWriteNoPermission) }
        if let variant = alteration {
            alteration = nil
            switch variant {
            case 0: try Data(#"{"schemaVersion":99,"records":[],"intents":[]}"#.utf8).write(to: dependency.url, options: .atomic)
            case 1: try JSONEncoder().encode(StudyMaterialState()).write(to: dependency.url, options: .atomic)
            case 2: try Data().write(to: dependency.url.deletingLastPathComponent().appendingPathComponent("study-state-conflict.json"))
            default: try JSONEncoder().encode([Flashcard(japanese: "外部", translation: "external")]).write(to: url, options: .atomic)
            }
        }
        return try await base.writeReviewedCards(cards, to: url, expectedRevision: expectedRevision, intent: intent, dependency: dependency)
    }
}
