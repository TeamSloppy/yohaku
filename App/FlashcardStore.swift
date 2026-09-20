import Foundation
import Observation

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
    var sourcePath: String?
    var sourcePageID: UUID?
    var sourceExcerpt: String?
    var lastReviewAt: Date?
    var lastRating: FlashcardRating?

    var reviewCount: Int { successfulReviews + failedReviews }

    var hasMistakes: Bool { failedReviews > 0 }

    var clozePrompt: String? {
        guard !japanese.isEmpty, !example.isEmpty,
              example.localizedStandardContains(japanese) else { return nil }
        return example.replacingOccurrences(of: japanese, with: "＿＿＿")
    }
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
}

enum FlashcardPracticeQueue {
    static func exercise(for card: Flashcard) -> FlashcardExercise {
        var modes: [FlashcardExerciseMode] = [.recognition]
        if !card.translation.isEmpty { modes.append(.production) }
        if card.clozePrompt != nil { modes.append(.cloze) }
        let index = card.reviewCount % modes.count
        return FlashcardExercise(card: card, mode: modes[index])
    }

    static func exercises(for cards: [Flashcard]) -> [FlashcardExercise] {
        cards.map(exercise(for:))
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
            if card.intervalDays == 0 { updated.intervalDays = 3 }
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
        fileURL = vaultRoot.appendingPathComponent(".workspace/flashcards.json")
        do {
            let url = try requireURL()
            cards = try await Task.detached(priority: .userInitiated) {
                guard FileManager.default.fileExists(atPath: url.path) else { return [] }
                return try JSONDecoder().decode([Flashcard].self, from: Data(contentsOf: url))
            }.value
            isLoaded = true
        } catch {
            cards = []
            isLoaded = true
            self.error = error.localizedDescription
        }
    }

    func add(_ card: Flashcard) async {
        cards.append(card)
        await save()
    }

    func add(_ newCards: [Flashcard]) async {
        var signatures = Set(cards.map(Self.signature))
        for card in newCards where signatures.insert(Self.signature(card)).inserted {
            cards.append(card)
        }
        await save()
    }

    func update(_ card: Flashcard) async {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[index] = card
        await save()
    }

    func delete(at offsets: IndexSet) async {
        cards.remove(atOffsets: offsets)
        await save()
    }

    func delete(id: UUID) async {
        cards.removeAll { $0.id == id }
        await save()
    }

    func review(id: UUID, rating: FlashcardRating, now: Date = Date()) async {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[index] = FlashcardScheduler.review(cards[index], rating: rating, now: now)
        await save()
    }

    private func save() async {
        do {
            let url = try requireURL()
            let snapshot = cards
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
            }.value
        } catch { self.error = error.localizedDescription }
    }

    private func requireURL() throws -> URL {
        guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
        return fileURL
    }

    private static func signature(_ card: Flashcard) -> String {
        card.japanese.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + card.translation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
