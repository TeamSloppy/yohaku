import Foundation
import Observation
import StudyCore
import StudyIntelligence

enum StudySourceTextOrigin: String, Codable, Sendable {
    case confirmedTranscription
    var label: String { "Подтверждённая расшифровка" }
}

struct Flashcard: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var japanese: String
    var reading = ""
    var translation: String
    var example = ""
    var note = ""
    var createdAt = Date()
    var dueAt = Date()
    var intervalDays = 0
    var successfulReviews = 0
    var failedReviews = 0
    var materialID: UUID?
    var appliedMaterialOperationID: UUID?
    var appliedLessonOperationID: UUID?
    var sourcePath: String?
    var sourcePageID: UUID?
    var sourceExcerpt: String?
    var sourceRegion: Rect?
    var sourceTextOrigin: StudySourceTextOrigin?
    var pitchAccent: String?
    var pronunciationAudio: FlashcardAudio?
    var lastReviewAt: Date?
    var lastRating: FlashcardRating?
    var handwriting: FlashcardHandwriting?
    var phrasePractice: PhrasePractice?
    var courseItemID: String?

    var reviewCount: Int { successfulReviews + failedReviews }

    var hasMistakes: Bool { failedReviews > 0 }

    func matchesSearch(_ query: String) -> Bool {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let fields = [japanese, reading, translation, example, note, sourceExcerpt ?? ""]
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }

    var clozePrompt: String? {
        guard !japanese.isEmpty, !example.isEmpty,
              example.localizedStandardContains(japanese) else { return nil }
        return example.replacingOccurrences(of: japanese, with: "＿＿＿")
    }
}

struct FlashcardHandwriting: Codable, Equatable, Sendable {
    var japanese: Data?
    var reading: Data?
    var translation: Data?

    var isEmpty: Bool { japanese == nil && reading == nil && translation == nil }
}

enum FlashcardAudioSource: String, Codable, CaseIterable, Sendable {
    case sourceClip
    case nativeSpeaker
    case kanjiAlive
    case forvo

    var title: String {
        switch self {
        case .sourceClip: "Фрагмент источника"
        case .nativeSpeaker: "Запись носителя"
        case .kanjiAlive: "Kanji alive · пример слова"
        case .forvo: "Forvo · запись носителя"
        }
    }
}

struct FlashcardAudio: Codable, Equatable, Sendable {
    var relativePath: String
    var fileName: String
    var source: FlashcardAudioSource
    var attribution: String?
    var sourceURL: URL?
}

enum FlashcardRating: String, Codable, Sendable {
    case forgot, hard, remembered
}

enum FlashcardExerciseMode: String, Codable, Equatable, Sendable {
    case recognition, production, cloze
}

struct FlashcardExercise: Identifiable, Equatable, Sendable {
    var card: Flashcard
    var mode: FlashcardExerciseMode
    var id: UUID { card.id }

    var prompt: String {
        switch mode {
        case .recognition: card.japanese
        case .production: card.translation
        case .cloze: card.clozePrompt ?? card.example
        }
    }

    var expectedAnswer: String { card.japanese }

    var promptHandwriting: Data? {
        switch mode {
        case .recognition: card.handwriting?.japanese
        case .production: card.handwriting?.translation
        case .cloze: nil
        }
    }
}

enum FlashcardPracticeQueue {
    static func exercise(for card: Flashcard) -> FlashcardExercise {
        if card.phrasePractice?.question(for: card) != nil { return FlashcardExercise(card: card, mode: .recognition) }
        var modes: [FlashcardExerciseMode] = [.recognition]
        if !card.translation.isEmpty || card.handwriting?.translation != nil { modes.append(.production) }
        if card.clozePrompt != nil { modes.append(.cloze) }
        let index = card.reviewCount % modes.count
        return FlashcardExercise(card: card, mode: modes[index])
    }

    static func exercises(for cards: [Flashcard], now: Date = Date(), limit: Int = 20) -> [FlashcardExercise] {
        var generator = SystemRandomNumberGenerator()
        return exercises(for: cards, now: now, limit: limit, using: &generator)
    }

    static func exercises<R: RandomNumberGenerator>(for cards: [Flashcard], now: Date, limit: Int, using generator: inout R) -> [FlashcardExercise] {
        // Exponential keys implement weighted sampling without replacement.
        cards.filter { $0.dueAt <= now }.map { card in
            let random = Double.random(in: Double.leastNonzeroMagnitude...1, using: &generator)
            return (card, -log(random) / priority(of: card, now: now))
        }
        .sorted { $0.1 < $1.1 }
        .prefix(max(0, limit))
        .map { exercise(for: $0.0) }
    }

    static func priority(of card: Flashcard, now: Date) -> Double {
        let interval = Double(max(1, card.intervalDays))
        let errorRate = Double(card.failedReviews) / Double(max(1, card.reviewCount))
        let recentDifficulty: Double = switch card.lastRating {
        case .forgot: 6
        case .hard: 3
        default: 0
        }
        let overdueDays = max(0, now.timeIntervalSince(card.dueAt) / 86_400)
        return 1 + (card.reviewCount == 0 ? 6 : 0) + recentDifficulty +
            4 * errorRate / sqrt(interval) + min(12, overdueDays / interval)
    }
}

enum FlashcardScheduler {
    static func review(_ card: Flashcard, rating: FlashcardRating, now: Date = Date(), calendar: Calendar = .current) -> Flashcard {
        var updated = card
        updated.lastReviewAt = now
        updated.lastRating = rating
        switch rating {
        case .forgot:
            updated.failedReviews += 1
            updated.intervalDays = 0
            updated.dueAt = calendar.date(byAdding: .minute, value: 10, to: now) ?? now.addingTimeInterval(600)
        case .hard:
            updated.successfulReviews += 1
            updated.intervalDays = max(1, card.intervalDays == 0 ? 1 : Int((Double(card.intervalDays) * 1.5).rounded()))
            updated.dueAt = calendar.date(byAdding: .day, value: updated.intervalDays, to: now) ?? now.addingTimeInterval(Double(updated.intervalDays) * 86_400)
        case .remembered:
            updated.successfulReviews += 1
            if card.lastRating == .forgot { updated.intervalDays = 1 }
            else if card.intervalDays == 0 { updated.intervalDays = 3 }
            else { updated.intervalDays = max(card.intervalDays + 1, Int((Double(card.intervalDays) * 2.2).rounded())) }
            updated.dueAt = calendar.date(byAdding: .day, value: updated.intervalDays, to: now) ?? now.addingTimeInterval(Double(updated.intervalDays) * 86_400)
        }
        return updated
    }
}

@MainActor @Observable final class FlashcardStore {
    private(set) var cards: [Flashcard] = []
    private(set) var isLoaded = false
    var error: String?
    private var fileURL: URL?
    private let writer: any StudyFileWriting
    private var revision: String?
    private var epoch = UUID()
    private var transactionTail: Task<Void, Never>?
    private(set) var isBlocked = true
    private let onCardsChanged: (@MainActor ([Flashcard]) async -> Void)?

    init(writer: any StudyFileWriting = StudyFileWriter(), onCardsChanged: (@MainActor ([Flashcard]) async -> Void)? = nil) {
        self.writer = writer
        self.onCardsChanged = onCardsChanged
    }

    var dueCards: [Flashcard] {
        cards.filter { $0.dueAt <= Date() }.sorted { $0.dueAt < $1.dueAt }
    }

    var mistakeCards: [Flashcard] {
        cards.filter(\.hasMistakes).sorted {
            if $0.failedReviews == $1.failedReviews { return $0.dueAt < $1.dueAt }
            return $0.failedReviews > $1.failedReviews
        }
    }

    func open(vaultRoot: URL) async {
        epoch = UUID()
        let request = epoch
        let url = vaultRoot.appendingPathComponent(".workspace/flashcards.json")
        fileURL = url
        cards = []
        isLoaded = false
        isBlocked = true
        error = nil
        _ = await enqueue { [self] in
            guard epoch == request else { return false }
            do {
                let snapshot = try await writer.load(url)
                guard epoch == request else { return false }
                cards = snapshot.cards
                revision = snapshot.revision
                isBlocked = snapshot.hasConflict
                error = snapshot.hasConflict ? StudyFileError.conflict.localizedDescription : nil
                isLoaded = true
                await onCardsChanged?(snapshot.cards)
                return epoch == request
            } catch {
                guard epoch == request else { return false }
                isLoaded = true
                self.error = error.localizedDescription
                return false
            }
        }
    }

    @discardableResult func recoverSavedVersion() async -> Bool {
        let request = epoch
        return await enqueue { [self] in
            guard epoch == request, let url = fileURL else { return false }
            do {
                let snapshot = try await writer.recover(url)
                guard epoch == request else { return false }
                cards = snapshot.cards
                revision = snapshot.revision
                isBlocked = false
                isLoaded = true
                error = nil
                await onCardsChanged?(snapshot.cards)
                return epoch == request
            } catch {
                guard epoch == request else { return false }
                self.error = error.localizedDescription
                return false
            }
        }
    }

    @discardableResult func add(_ card: Flashcard) async -> Bool {
        await mutate { $0.append(card); return true }
    }

    @discardableResult func add(_ newCards: [Flashcard], ifCurrent: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        await mutate { cards in
            guard ifCurrent() else { return false }
            var signatures = Set(cards.map(Self.signature))
            cards.append(contentsOf: newCards.filter { signatures.insert(Self.signature($0)).inserted })
            return true
        }
    }

    @discardableResult func addComposedPhrases(_ phrases: [ComposedPhrase], inputs: [PhraseWord], kana: Set<String>,
        now: Date = Date(), calendar: Calendar = .current, ifCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        await mutate { cards in
            let current = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            guard (2...24).contains(inputs.count), !phrases.isEmpty, ifCurrent(), inputs.allSatisfy({ word in current[word.id].map { PhrasePractice.isKnown($0) && PhrasePractice.word($0) == word } == true }) else { return false }
            let used = cards.filter { $0.phrasePractice.map { calendar.isDate($0.generatedAt, inSameDayAs: now) } == true }.count
            var remaining = max(0, 3 - used), signatures = Set(cards.map(Self.signature))
            var compositions = Set(cards.compactMap { $0.phrasePractice?.signature })
            for phrase in phrases where remaining > 0 {
                guard phrase.words.allSatisfy(inputs.contains) else { continue }
                let card = PhrasePractice.card(phrase, kana: kana, now: now)
                guard signatures.insert(Self.signature(card)).inserted,
                      let signature = card.phrasePractice?.signature, compositions.insert(signature).inserted else { continue }
                cards.append(card); remaining -= 1
            }
            return true
        }
    }

    /// The callback runs inside the card FIFO. It must persist directly, without re-entering either queue.
    func importMaterial(_ material: StudyMaterialRecord,
                        persistIntent: @escaping @MainActor (StudyAcceptanceIntent) async throws -> StudyStateDependency) async throws -> StudyAcceptanceIntent {
        let request = epoch
        var result: Result<StudyAcceptanceIntent, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do {
                guard epoch == request else { throw StudyImportError.staleVault }
                guard isLoaded, !isBlocked else { throw StudyImportError.unavailable }
                var card = material.makeCard()
                let existing = cards.first { $0.handwriting == nil && StudyMaterialFields($0).fingerprint == material.fields.fingerprint }
                if let existing { card = existing }
                var intent = StudyAcceptanceIntent(materialID: material.id, card: card,
                                                   expectedCardRevision: revision, createsCard: existing == nil)
                if existing == nil { intent.card.appliedMaterialOperationID = intent.id }
                let dependency = try await persistIntent(intent)
                try await applyImport(intent, dependency: dependency, request: request)
                result = .success(intent)
            } catch { result = .failure(error) }
            return true
        }
        return try result.get()
    }

    func recoverMaterialImport(_ intent: StudyAcceptanceIntent, dependency: StudyStateDependency) async throws {
        let request = epoch
        var result: Result<Void, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do { try await applyImport(intent, dependency: dependency, request: request, recovering: true); result = .success(()) }
            catch { result = .failure(error) }
            return true
        }
        try result.get()
    }

    private func applyImport(_ intent: StudyAcceptanceIntent, dependency: StudyStateDependency, request: UUID, recovering: Bool = false) async throws {
        guard epoch == request else { throw StudyImportError.staleVault }
        guard isLoaded, !isBlocked, let url = fileURL else { throw StudyImportError.unavailable }
        var candidate = cards
        if !cards.contains(where: { $0.id == intent.card.id }) {
            // Existing bytes may be identical after a create/delete cycle. Historical absence is ambiguous.
            guard intent.createsCard, revision == intent.expectedCardRevision,
                  !recovering || intent.expectedCardRevision == nil else { throw StudyImportError.ambiguous }
            candidate.append(intent.card)
        }
        do {
            let saved = try await writer.writeImportedCards(candidate, to: url, expectedRevision: revision,
                                                           intent: intent, dependency: dependency)
            guard epoch == request else { throw StudyImportError.staleVault }
            cards = candidate; revision = saved; error = nil
            await onCardsChanged?(candidate)
            guard epoch == request else { throw StudyImportError.staleVault }
        } catch {
            if epoch == request, error as? StudyFileError == .conflict { isBlocked = true }
            throw error
        }
    }

    /// Retain the card FIFO until the state owner durably saves the verified selection.
    func captureLesson(_ exercises: [FlashcardExercise], now: Date, ifCurrent: @escaping @MainActor () -> Bool,
                       persist: @escaping @MainActor () async throws -> DailyLessonState) async throws -> DailyLessonState {
        let request = epoch
        var result: Result<DailyLessonState, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do {
                guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
                guard isLoaded, !isBlocked, let url = fileURL else { throw StudyImportError.unavailable }
                guard exercises.allSatisfy({ exercise in cards.contains { $0 == exercise.card && $0.dueAt <= now } }) else {
                    throw DailyLessonError.selectionChanged
                }
                revision = try await writer.write(cards, to: url, expectedRevision: revision)
                guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
                let saved = try await persist()
                guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
                result = .success(saved)
            } catch {
                if epoch == request, error as? StudyFileError == .conflict { isBlocked = true; self.error = error.localizedDescription }
                result = .failure(error)
            }
            return true
        }
        return try result.get()
    }

    func reviewLesson(_ step: DailyLessonStep, lessonID: UUID, rating: FlashcardRating, now: Date, calendar: Calendar,
                      dependency: StudyStateDependency, ifCurrent: @escaping @MainActor () -> Bool,
                      persistIntent: @escaping @MainActor (DailyLessonReviewIntent) async throws -> StudyStateDependency) async throws -> DailyLessonOutcome {
        let request = epoch
        var result: Result<DailyLessonOutcome, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do {
                guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
                guard isLoaded, !isBlocked else { throw StudyImportError.unavailable }
                if let current = cards.first(where: { $0.id == step.card.id }) {
                    if step.matches(current) {
                        var intent = DailyLessonReviewIntent(lessonID: lessonID, stepID: step.id, rating: rating,
                            reviewedCard: FlashcardScheduler.review(current, rating: rating, now: now, calendar: calendar), expectedCardRevision: revision)
                        intent.reviewedCard.appliedLessonOperationID = intent.id
                        let dependency = try await persistIntent(intent)
                        try await applyLessonReview(intent, dependency: dependency, request: request, recovering: false, ifCurrent: ifCurrent)
                        result = .success(.init(stepID: step.id, kind: .reviewed, rating: rating, operationID: intent.id))
                    } else {
                        try await verifyLessonCards(dependency: dependency, request: request, ifCurrent: ifCurrent)
                        result = .success(.init(stepID: step.id, kind: .edited))
                    }
                } else {
                    try await verifyLessonCards(dependency: dependency, request: request, ifCurrent: ifCurrent)
                    result = .success(.init(stepID: step.id, kind: .deleted))
                }
            } catch { result = .failure(error) }
            return true
        }
        return try result.get()
    }

    func recoverLessonReview(_ intent: DailyLessonReviewIntent, dependency: StudyStateDependency) async throws -> DailyLessonOutcome {
        let request = epoch
        var result: Result<DailyLessonOutcome, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do {
                let kind = try await applyLessonReview(intent, dependency: dependency, request: request, recovering: true)
                result = .success(.init(stepID: intent.stepID, kind: kind,
                    rating: kind == .reviewed ? intent.rating : nil, operationID: kind == .reviewed ? intent.id : nil))
            } catch { result = .failure(error) }
            return true
        }
        return try result.get()
    }

    @discardableResult private func applyLessonReview(_ intent: DailyLessonReviewIntent, dependency: StudyStateDependency,
                                                     request: UUID, recovering: Bool, ifCurrent: @escaping @MainActor () -> Bool = { true }) async throws -> DailyLessonOutcome.Kind {
        guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
        guard isLoaded, !isBlocked, let url = fileURL else { throw StudyImportError.unavailable }
        guard let index = cards.firstIndex(where: { $0.id == intent.reviewedCard.id }) else {
            try await verifyLessonCards(dependency: dependency, request: request, ifCurrent: ifCurrent)
            return .deleted
        }
        var candidate = cards
        if cards[index].appliedLessonOperationID != intent.id {
            // Raw-byte equality cannot prove non-application after an external rollback (ABA).
            guard !recovering else { throw DailyLessonError.ambiguous }
            guard revision == intent.expectedCardRevision else { throw StudyImportError.dependencyChanged }
            candidate[index] = intent.reviewedCard
        }
        do {
            let saved = try await writer.writeReviewedCards(candidate, to: url, expectedRevision: revision, intent: intent, dependency: dependency)
            guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
            cards = candidate; revision = saved; error = nil
            await onCardsChanged?(candidate)
            guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
            return .reviewed
        } catch {
            if epoch == request, error as? StudyFileError == .conflict { isBlocked = true; self.error = error.localizedDescription }
            throw error
        }
    }

    func verifyLessonCheckpoint(dependency: StudyStateDependency, ifCurrent: @escaping @MainActor () -> Bool) async throws {
        let request = epoch
        var result: Result<Void, Error> = .failure(StudyImportError.staleVault)
        _ = await enqueue { [self] in
            do { try await verifyLessonCards(dependency: dependency, request: request, ifCurrent: ifCurrent); result = .success(()) }
            catch { result = .failure(error) }
            return true
        }
        try result.get()
    }
    private func verifyLessonCards(dependency: StudyStateDependency, request: UUID, ifCurrent: @escaping @MainActor () -> Bool) async throws {
        guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
        guard isLoaded, !isBlocked, let url = fileURL else { throw StudyImportError.unavailable }
        do {
            try await writer.verifyLessonCards(cards, at: url, expectedRevision: revision, dependency: dependency)
            guard epoch == request, ifCurrent() else { throw StudyImportError.staleVault }
        } catch {
            if epoch == request, error as? StudyFileError == .conflict { isBlocked = true; self.error = error.localizedDescription }
            throw error
        }
    }

    @discardableResult func update(_ card: Flashcard) async -> Bool {
        await mutate { cards in
            guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return false }
            // An editor draft may predate a queued review. Only replace editable content.
            let current = cards[index]
            var updated = card
            updated.createdAt = current.createdAt
            updated.dueAt = current.dueAt
            updated.intervalDays = current.intervalDays
            updated.successfulReviews = current.successfulReviews
            updated.failedReviews = current.failedReviews
            updated.lastReviewAt = current.lastReviewAt
            updated.lastRating = current.lastRating
            updated.appliedLessonOperationID = current.appliedLessonOperationID
            updated.phrasePractice = current.phrasePractice
            cards[index] = updated
            return true
        }
    }

    @discardableResult func delete(at offsets: IndexSet) async -> Bool {
        let ids = Set(offsets.compactMap { cards.indices.contains($0) ? cards[$0].id : nil })
        return await mutate { $0.removeAll { ids.contains($0.id) }; return true }
    }

    @discardableResult func delete(id: UUID) async -> Bool {
        await mutate { $0.removeAll { $0.id == id }; return true }
    }

    @discardableResult func review(id: UUID, rating: FlashcardRating, now: Date = Date()) async -> Bool {
        await mutate { cards in
            guard let index = cards.firstIndex(where: { $0.id == id }) else { return false }
            cards[index] = FlashcardScheduler.review(cards[index], rating: rating, now: now)
            return true
        }
    }

    func importPronunciationAudio(from sourceURL: URL, source: FlashcardAudioSource) async throws -> FlashcardAudio {
        let workspaceURL = try requireURL().deletingLastPathComponent()
        let directoryURL = workspaceURL.appendingPathComponent("study-audio", isDirectory: true)
        let pathExtension = sourceURL.pathExtension.isEmpty ? "audio" : sourceURL.pathExtension.lowercased()
        let fileName = "\(UUID().uuidString).\(pathExtension)"
        let destinationURL = directoryURL.appendingPathComponent(fileName)

        try await Task.detached(priority: .userInitiated) {
            let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
            defer { if hasScopedAccess { sourceURL.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        }.value

        return FlashcardAudio(
            relativePath: "study-audio/\(fileName)",
            fileName: sourceURL.lastPathComponent,
            source: source,
            attribution: nil,
            sourceURL: nil
        )
    }

    func storePronunciationAudio(
        _ data: Data,
        fileName: String,
        source: FlashcardAudioSource,
        attribution: String?,
        sourceURL: URL?
    ) async throws -> FlashcardAudio {
        let workspaceURL = try requireURL().deletingLastPathComponent()
        let directoryURL = workspaceURL.appendingPathComponent("study-audio", isDirectory: true)
        let pathExtension = (fileName as NSString).pathExtension.isEmpty ? "mp3" : (fileName as NSString).pathExtension.lowercased()
        let storedName = "\(UUID().uuidString).\(pathExtension)"
        let destinationURL = directoryURL.appendingPathComponent(storedName)
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)
        }.value
        return FlashcardAudio(
            relativePath: "study-audio/\(storedName)",
            fileName: fileName,
            source: source,
            attribution: attribution,
            sourceURL: sourceURL
        )
    }

    func pronunciationAudioURL(for audio: FlashcardAudio) -> URL? {
        guard let fileURL else { return nil }
        return fileURL.deletingLastPathComponent().appendingPathComponent(audio.relativePath)
    }

    func deletePronunciationAudio(_ audio: FlashcardAudio) async {
        guard let url = pronunciationAudioURL(for: audio) else { return }
        let workspaceURL = url.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let candidateURL = url.standardizedFileURL
        guard candidateURL.path.hasPrefix(workspaceURL.appendingPathComponent("study-audio", isDirectory: true).path + "/") else { return }
        try? await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: candidateURL)
        }.value
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Bool) async -> Bool {
        let previous = transactionTail
        let task = Task { @MainActor in
            await previous?.value
            return await operation()
        }
        transactionTail = Task { _ = await task.value }
        return await task.value
    }

    func addCourseCards(_ incoming: [Flashcard], ifCurrent: @escaping @MainActor () -> Bool) async -> Bool {
        await mutate { cards in
            guard ifCurrent() else { return false }
            for card in incoming {
                guard let key = card.courseItemID, !cards.contains(where: { $0.courseItemID == key }) else { continue }
                if let index = cards.firstIndex(where: { $0.japanese == card.japanese && $0.translation == card.translation && $0.courseItemID == nil }) {
                    cards[index].courseItemID = key
                } else { cards.append(card) }
            }
            return true
        }
    }
    private func mutate(_ change: @escaping @MainActor (inout [Flashcard]) -> Bool) async -> Bool {
        let request = epoch
        return await enqueue { [self] in
            guard epoch == request else { return false }
            guard isLoaded, !isBlocked, let url = fileURL else {
                if error == nil { error = "Хранилище карточек недоступно для записи." }
                return false
            }
            var candidate = cards
            guard change(&candidate) else { return false }
            do {
                let savedRevision = try await writer.write(candidate, to: url, expectedRevision: revision)
                guard epoch == request else { return false }
                cards = candidate
                revision = savedRevision
                error = nil
                await onCardsChanged?(candidate)
                return epoch == request
            } catch {
                guard epoch == request else { return false }
                if let failure = error as? StudyFileError, failure == .conflict { isBlocked = true }
                self.error = error.localizedDescription
                return false
            }
        }
    }

    private func requireURL() throws -> URL {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        return fileURL
    }

    private static func signature(_ card: Flashcard) -> String {
        if card.handwriting != nil { return card.id.uuidString }
        return card.japanese.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + card.translation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
