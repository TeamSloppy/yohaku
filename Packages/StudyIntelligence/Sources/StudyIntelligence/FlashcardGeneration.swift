import Foundation

public struct GeneratedFlashcard: Codable, Equatable, Sendable {
    public var japanese: String
    public var reading: String
    public var translation: String
    public var example: String
    public var note: String

    public init(japanese: String, reading: String = "", translation: String, example: String = "", note: String = "") {
        self.japanese = japanese
        self.reading = reading
        self.translation = translation
        self.example = example
        self.note = note
    }
}

enum FlashcardGenerationParser {
    static func parse(_ text: String, limit: Int) throws -> [GeneratedFlashcard] {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("```") {
            source = source.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            source = source.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        guard let first = source.firstIndex(of: "["), let last = source.lastIndex(of: "]"), first <= last else {
            throw ModelConnectionError.message(String(localized: "Модель не вернула список карточек. Попробуйте уточнить тему."))
        }
        let data = Data(source[first...last].utf8)
        let decoded = try JSONDecoder().decode([GeneratedFlashcard].self, from: data)
        var signatures = Set<String>()
        return decoded.compactMap { card in
            var clean = card
            clean.japanese = clean.japanese.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.reading = clean.reading.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.translation = clean.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.example = clean.example.trimmingCharacters(in: .whitespacesAndNewlines)
            clean.note = clean.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.japanese.isEmpty, !clean.translation.isEmpty,
                  clean.japanese.count <= 240, clean.translation.count <= 500,
                  clean.reading.count <= 240, clean.example.count <= 800, clean.note.count <= 800 else { return nil }
            let signature = clean.japanese.lowercased() + "|" + clean.translation.lowercased()
            guard signatures.insert(signature).inserted else { return nil }
            return clean
        }.prefix(max(1, min(limit, 30))).map { $0 }
    }
}
