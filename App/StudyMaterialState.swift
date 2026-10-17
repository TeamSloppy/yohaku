import Foundation
import StudyCore

struct StudyMaterialFields: Codable, Equatable, Sendable {
    var japanese: String
    var reading: String
    var translation: String
    var example: String
    var note: String
    init(_ card: Flashcard) {
        japanese = card.japanese; reading = card.reading; translation = card.translation
        example = card.example; note = card.note
    }
    var fingerprint: [String] {
        [japanese, reading, translation, example, note].map {
            $0.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
    }
}

struct StudyMaterialSource: Codable, Equatable, Sendable {
    var vaultID: String
    var documentID: UUID
    var contentRevision: String
    var path: String
    var pageID: UUID?
    var region: Rect?
    var excerpt: String
    var quote: String
    var origin: StudySourceTextOrigin?
    func sameScope(as other: Self) -> Bool {
        vaultID == other.vaultID && documentID == other.documentID && pageID == other.pageID && region == other.region
    }
}

struct StudyMaterialRecord: Codable, Equatable, Identifiable, Sendable {
    enum Disposition: String, Codable, Sendable { case pending, accepted, rejected }
    enum Freshness: String, Codable, Sendable { case current, stale, missing }
    var id = UUID()
    var fields: StudyMaterialFields
    var source: StudyMaterialSource
    var disposition = Disposition.pending
    var freshness = Freshness.current
    var cardID: UUID?
    var sourceSuperseded: Bool?
    func makeCard() -> Flashcard {
        var card = Flashcard(japanese: fields.japanese, reading: fields.reading, translation: fields.translation,
                             example: fields.example, note: fields.note)
        card.sourcePath = source.path; card.sourcePageID = source.pageID; card.sourceRegion = source.region
        card.sourceExcerpt = source.quote; card.sourceTextOrigin = source.origin; card.materialID = id
        return card
    }
}

struct StudyAcceptanceIntent: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var materialID: UUID
    var card: Flashcard
    var expectedCardRevision: String?
    var createsCard: Bool
}

struct StudyMaterialState: Codable, Equatable, Sendable {
    var schemaVersion = 2
    var records: [StudyMaterialRecord] = []
    var intents: [StudyAcceptanceIntent] = []
    var lesson: DailyLessonState?
    var lessonIntent: DailyLessonReviewIntent?
    var completions: [DailyLessonCompletion] = []
    init(records: [StudyMaterialRecord] = [], intents: [StudyAcceptanceIntent] = [],
         lesson: DailyLessonState? = nil, lessonIntent: DailyLessonReviewIntent? = nil,
         completions: [DailyLessonCompletion] = []) {
        self.records = records; self.intents = intents; self.lesson = lesson
        self.lessonIntent = lessonIntent; self.completions = completions
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, records, intents, lesson, lessonIntent, completions }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw StudyError.unsupportedVersion }
        records = try values.decode([StudyMaterialRecord].self, forKey: .records)
        intents = try values.decode([StudyAcceptanceIntent].self, forKey: .intents)
        lesson = try values.decodeIfPresent(DailyLessonState.self, forKey: .lesson)
        lessonIntent = try values.decodeIfPresent(DailyLessonReviewIntent.self, forKey: .lessonIntent)
        completions = try values.decodeIfPresent([DailyLessonCompletion].self, forKey: .completions) ?? []
        try validate()
    }
    func validate() throws {
        try lesson?.validate()
        guard completions.count <= 32, Set(completions.map(\.lessonID)).count == completions.count,
              lessonIntent == nil || intents.isEmpty else { throw DailyLessonError.invalidSnapshot }
        if let lesson, let completedAt = lesson.completedAt {
            guard completions.contains(where: { $0.lessonID == lesson.id && $0.completedAt == completedAt }) else { throw DailyLessonError.invalidSnapshot }
        }
        guard completions.allSatisfy({ TimeZone(identifier: $0.timeZoneID) != nil && (0...DailyLessonState.maximumSteps).contains($0.reviewed) &&
            (0...DailyLessonState.maximumSteps).contains($0.skipped) &&
            (1...DailyLessonState.maximumSteps).contains($0.reviewed + $0.skipped) }) else { throw DailyLessonError.invalidSnapshot }
        if let intent = lessonIntent {
            guard let lesson, let step = lesson.current, intent.lessonID == lesson.id, intent.stepID == step.id,
                  intent.reviewedCard.id == step.card.id, step.matches(intent.reviewedCard),
                  intent.reviewedCard.lastRating == intent.rating, intent.reviewedCard.appliedLessonOperationID == intent.id else {
                throw DailyLessonError.invalidSnapshot
            }
        }
    }
    static func decode(_ data: Data?) throws -> Self {
        try data.map { try JSONDecoder().decode(Self.self, from: $0) } ?? Self()
    }
}

struct StudyStateSnapshot: Sendable {
    var state: StudyMaterialState
    var revision: String?
    var hasConflict: Bool
}
struct StudyStateDependency: Sendable {
    var url: URL
    var revision: String
}

enum StudyImportError: Error, LocalizedError, Equatable {
    case unavailable, dependencyChanged, ambiguous, staleVault
    var errorDescription: String? {
        switch self {
        case .unavailable: "Хранилище материалов недоступно для записи."
        case .dependencyChanged: "Журнал материалов изменён. Загрузите сохранённую версию перед продолжением."
        case .ambiguous: "Карточка отсутствует, а библиотека изменилась. Отмените незавершённое принятие перед новой попыткой."
        case .staleVault: "Хранилище изменилось. Откройте материалы повторно."
        }
    }
}
