import Foundation
import StudyIntelligence
import Testing
@testable import Yohaku

@MainActor @Suite(.serialized) struct PhrasePracticeTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
    private func known() -> [Flashcard] {
        [Flashcard(japanese: "大きい", reading: "おおきい", translation: "большой", dueAt: now.addingTimeInterval(86_400), successfulReviews: 2, lastRating: .remembered),
         Flashcard(japanese: "家", reading: "いえ", translation: "дом", dueAt: now.addingTimeInterval(86_400), successfulReviews: 2, lastRating: .remembered)]
    }
    private func drafts(_ words: [PhraseWord], between: String = "", answer: String = "Большой дом", alternatives: [String] = ["Маленький дом", "Большая школа", "Новый дом"]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [["wordIDs": words.map { $0.id.uuidString }, "between": [between], "translation": answer,
            "alternatives": alternatives, "explanation": "大きい — большой, 家 — дом", "japanese": "НЕ ДОВЕРЯТЬ"]]), as: UTF8.self)
    }
    private func phrases(_ words: [PhraseWord]) throws -> [ComposedPhrase] { try PhraseComposition.parse(drafts(words), words: words, kana: []) }
    private func profile() -> StudyLearningProfile {
        StudyLearningProfile(defaults: UserDefaults(suiteName: "phrase-tests-" + UUID().uuidString)!)
    }

    @Test func onlyKnownWordsAndPracticedParticlesCanReachPrompt() throws {
        let words = known().map(PhrasePractice.word)
        let result = try phrases(words)
        #expect(result.count == 1); #expect(result[0].japanese == "大きい家")
        #expect(result[0].reading == "おおきいいえ")
        #expect(try PhraseComposition.parse(drafts(words, between: "の"), words: words, kana: []).isEmpty)
        #expect(try PhraseComposition.parse(drafts(words, between: "の"), words: words, kana: ["の"]).count == 1)
        #expect(try PhraseComposition.parse(drafts(words, alternatives: [" 大きい", "同じ", "同じ"]), words: words, kana: []).isEmpty)
        #expect(try PhraseComposition.parse(drafts(words, answer: " " ), words: words, kana: []).isEmpty)
        #expect(try PhraseComposition.parse(drafts(words), words: Array(words.prefix(1)), kana: []).isEmpty)
        #expect(throws: Error.self) { try PhraseComposition.parse(String(repeating: "x", count: 32_769), words: words, kana: []) }
        let long = words.map { PhraseWord(id: $0.id, japanese: $0.japanese, reading: String(repeating: "あ", count: 241), translation: $0.translation) }
        #expect(try PhraseComposition.parse(drafts(long), words: long, kana: []).isEmpty)
    }

    @Test func stableChoicesKanaAndLegacyRoundtrip() throws {
        let words = known().map(PhrasePractice.word), phrase = try phrases(words)[0]
        let original = PhrasePractice.card(phrase, kana: [], now: now)
        let decoded = try JSONDecoder().decode(Flashcard.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(FlashcardQuiz.question(for: decoded, vocabulary: []) == FlashcardQuiz.question(for: original, vocabulary: []))
        #expect(FlashcardQuiz.question(for: decoded, vocabulary: [])?.choices.count == 4)
        #expect(PhrasePractice.card(phrase, kana: Set(phrase.reading.map(String.init)), now: now).japanese == phrase.reading)
        #expect(PhrasePractice.card(phrase, kana: ["お"], now: now).japanese == phrase.japanese)
        let blankReading = words.map { PhraseWord(id: $0.id, japanese: $0.japanese, reading: " ", translation: $0.translation) }
        #expect(PhrasePractice.card(try phrases(blankReading)[0], kana: [], now: now).japanese == phrase.japanese)
        var edited = original; edited.translation = "edited"; #expect(edited.phrasePractice?.question(for: edited) == nil)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known()[0])) as! [String: Any]
        object.removeValue(forKey: "phrasePractice")
        #expect(try JSONDecoder().decode(Flashcard.self, from: JSONSerialization.data(withJSONObject: object)).phrasePractice == nil)
        var reviewed = original; reviewed.successfulReviews = 5; reviewed.lastRating = .remembered
        #expect(!PhrasePractice.isKnown(reviewed))
        var forgot = known()[0]; forgot.lastRating = .forgot; #expect(!PhrasePractice.isKnown(forgot))
    }

    @Test func learnedKanaAndDailyReceiptPersist() {
        let defaults = UserDefaults(suiteName: "phrase-tests-" + UUID().uuidString)!
        let first = StudyLearningProfile(defaults: defaults)
        first.recordKana("あ"); first.recordKana("あ"); first.recordKana("家"); first.recordKana("abc")
        first.finishGeneration(vault: "first", day: "today")
        let reopened = StudyLearningProfile(defaults: defaults)
        #expect(reopened.knownKana == ["あ"])
        #expect(reopened.generated(vault: "first", day: "today"))
        #expect(!reopened.generated(vault: "other", day: "today")); #expect(!reopened.generated(vault: "first", day: "tomorrow"))
    }

    @Test func savingDeduplicatesCapsAndRejectsChangedInputs() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FlashcardStore(); await store.open(vaultRoot: root)
        let originals = known(), words = originals.map(PhrasePractice.word), phrases = try phrases(words)
        #expect(await store.add(originals))
        for index in 0..<5 {
            let variant = try PhraseComposition.parse(drafts(words, answer: "дом \(index)"), words: words, kana: [])
            #expect(await store.addComposedPhrases(variant, inputs: words, kana: [], now: now, calendar: calendar, ifCurrent: { true }))
        }
        #expect(store.cards.count == 5)
        #expect(await store.addComposedPhrases(phrases, inputs: words, kana: [], now: now, ifCurrent: { false }) == false)
        let reopened = FlashcardStore(); await reopened.open(vaultRoot: root)
        #expect(reopened.cards == store.cards)
        #expect(await reopened.review(id: originals[0].id, rating: .forgot, now: now))
        #expect(await reopened.addComposedPhrases(phrases, inputs: words, kana: [], now: now, ifCurrent: { true }) == false)
        #expect(reopened.cards.count == 5)
    }

    @Test func automaticPreparationRetriesThenRunsOncePerDayAcrossReopen() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile(), workspace = WorkspaceModel(learningProfile: profile), date = now
        try await workspace.openVault(root, remember: false); #expect(await workspace.flashcards.add(known()))
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in throw CancellationError() }
        #expect(!workspace.phrasePreparing); #expect(workspace.flashcards.cards.count == 2)
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { words, _ in try phrases(words) }
        #expect(workspace.flashcards.cards.count == 3); #expect(workspace.phraseError == nil)
        let reopened = WorkspaceModel(learningProfile: profile); try await reopened.openVault(root, remember: false)
        await reopened.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in Issue.record("repeated generation"); return [] }
        #expect(reopened.flashcards.cards.count == 3)
    }

    @Test(arguments: ["vault", "day", "model", "skip"]) func staleGenerationCannotSave(mode: String) async throws {
        let first = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), second = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let workspace = WorkspaceModel(learningProfile: profile()), gate = PhraseGate()
        let originalConfiguration = workspace.agent.configuration
        defer { workspace.agent.configuration = originalConfiguration }
        var date = now
        try await workspace.openVault(first, remember: false); #expect(await workspace.flashcards.add(known()))
        let task = Task { await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { words, _ in
            await gate.pause(); return try phrases(words)
        } }
        await gate.wait()
        switch mode {
        case "vault": try await workspace.openVault(second, remember: false)
        case "day": date = now.addingTimeInterval(86_400)
        case "model": workspace.agent.configuration.localID += "-changed"
        default: workspace.skipAutomaticPhrases()
        }
        await gate.resume(); await task.value
        #expect(workspace.flashcards.cards.allSatisfy { $0.phrasePractice == nil }); #expect(!workspace.phrasePreparing)
        let old = FlashcardStore(); await old.open(vaultRoot: first); #expect(old.cards.count == 2)
    }

    @Test func failedGenerationNeedsExplicitRetryAndEmptyOutputDoesNotFinishDay() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel(learningProfile: profile()), date = now
        try await workspace.openVault(root, remember: false); #expect(await workspace.flashcards.add(known()))
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in [] }
        #expect(workspace.phraseError != nil); #expect(!workspace.phrasePreparing)
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in Issue.record("automatic retry loop"); return [] }
        await workspace.prepareAutomaticPhrases(retry: true, clock: { date }, calendar: calendar) { words, _ in try phrases(words) }
        #expect(workspace.phraseError == nil); #expect(workspace.flashcards.cards.count == 3)
    }

    @Test func plannerCapsNewPhrasesAndKeepsDueWordsFirst() throws {
        let words = known().map(PhrasePractice.word)
        let generated = try (0..<4).map { index in
            PhrasePractice.card(try PhraseComposition.parse(drafts(words, answer: "дом \(index)"), words: words, kana: [])[0], kana: [], now: now)
        }
        var due = known()[0]; due.dueAt = now
        let unused = (0..<6).map { Flashcard(japanese: "語\($0)", translation: "word", dueAt: now) }
        for duration in DailyLessonDuration.allCases {
            let plan = DailyLessonPlanner.plan(cards: unused + generated + [due], materials: [], duration: duration, now: now, calendar: calendar)
            #expect(plan.items.first?.id == due.id)
            #expect(plan.items.filter { $0.exercise.card.phrasePractice != nil }.count == min(2, duration.newLimit))
            #expect(plan.items.count == 1 + duration.newLimit)
        }
    }

    @Test func frozenLessonGradesPhraseOnceWithoutChangingIngredients() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cards = FlashcardStore(), materials = StudyMaterialStore(writer: StudyFileWriter()), original = known(), date = now, zone = calendar
        await cards.open(vaultRoot: root); await materials.open(vaultRoot: root, cards: cards)
        #expect(await cards.add(original))
        let words = original.map(PhrasePractice.word)
        #expect(await cards.addComposedPhrases(try phrases(words), inputs: words, kana: [], now: now, ifCurrent: { true }))
        let plan = DailyLessonPlanner.plan(cards: cards.cards, materials: [], duration: .standard, now: now, calendar: calendar)
        #expect(plan.items.count == 1); #expect(plan.items[0].exercise.mode == .recognition)
        let lesson = try await materials.startLesson(plan, duration: .standard, cards: cards, now: now, calendar: calendar)
        let reopened = StudyMaterialStore(writer: StudyFileWriter()); await reopened.open(vaultRoot: root, cards: cards)
        #expect(reopened.lesson == lesson)
        let workspace = WorkspaceModel(learningProfile: profile()); try await workspace.openVault(root, remember: false)
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in Issue.record("active lesson changed"); return [] }
        for _ in 0..<2 {
            _ = try await reopened.submitLessonStep(lessonID: lesson.id, stepID: lesson.current!.id, rating: .forgot, cards: cards, clock: { date }, calendar: { zone })
        }
        #expect(reopened.lesson?.isComplete == true)
        #expect(cards.cards.first { $0.phrasePractice != nil }?.failedReviews == 1)
        #expect(Array(cards.cards.prefix(2)) == original)
        try await workspace.openVault(root, remember: false)
        await workspace.prepareAutomaticPhrases(clock: { date }, calendar: calendar) { _, _ in Issue.record("completed lesson changed"); return [] }
    }
}

private actor PhraseGate {
    private var paused: CheckedContinuation<Void, Never>?
    private var started = false
    func pause() async { started = true; await withCheckedContinuation { paused = $0 } }
    func wait() async { while !started { await Task.yield() } }
    func resume() { paused?.resume(); paused = nil }
}
