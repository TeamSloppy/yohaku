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
    // A stored var is deliberately decoded; a constant default would silently ignore a newer version.
    var schemaVersion = 1
    var records: [StudyMaterialRecord] = []
    var intents: [StudyAcceptanceIntent] = []
    static func decode(_ data: Data?) throws -> Self {
        guard let data else { return Self() }
        struct Header: Decodable { var schemaVersion: Int }
        guard try JSONDecoder().decode(Header.self, from: data).schemaVersion == 1 else { throw StudyError.unsupportedVersion }
        return try JSONDecoder().decode(Self.self, from: data)
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
