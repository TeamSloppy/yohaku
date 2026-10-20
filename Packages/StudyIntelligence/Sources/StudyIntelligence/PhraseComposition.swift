import Foundation

public struct PhraseWord: Codable, Equatable, Sendable {
    public let id: UUID
    public let japanese: String
    public let reading: String
    public let translation: String
    public init(id: UUID, japanese: String, reading: String, translation: String) {
        self.id = id; self.japanese = japanese; self.reading = reading; self.translation = translation
    }
}

public struct ComposedPhrase: Equatable, Sendable {
    public let japanese: String
    public let reading: String
    public let translation: String
    public let alternatives: [String]
    public let words: [PhraseWord]
    public let explanation: String
}

public enum PhraseComposition {
    private struct Draft: Decodable {
        var wordIDs: [UUID]
        var between: [String]
        var translation: String
        var alternatives: [String]
        var explanation: String
    }
    public static func particles(words: [PhraseWord], kana: Set<String>, allowedParticles: Set<String>? = nil) -> [String] {
        let known = kana.union(words.flatMap { $0.japanese.map(String.init) })
        return ["", "の", "は", "が", "と", "も", "に", "へ", "で", "を"].filter {
            (allowedParticles == nil || $0.isEmpty || allowedParticles!.contains($0)) && $0.allSatisfy { known.contains(String($0)) }
        }
    }
    public static func parse(_ text: String, words: [PhraseWord], kana: Set<String>, limit: Int = 3, allowedParticles: Set<String>? = nil) throws -> [ComposedPhrase] {
        guard text.utf8.count <= 32_768, words.count <= 24,
              Set(words.map(\.id)).count == words.count,
              let first = text.firstIndex(of: "["), let last = text.lastIndex(of: "]"), first <= last else {
            throw ModelConnectionError.message("Модель не вернула корректные фразы.")
        }
        let drafts = try JSONDecoder().decode([Draft].self, from: Data(text[first...last].utf8))
        let vocabulary = Dictionary(uniqueKeysWithValues: words.map { ($0.id, $0) })
        let allowed = Set(particles(words: words, kana: kana, allowedParticles: allowedParticles))
        var seen = Set<String>()
        return drafts.compactMap { draft -> ComposedPhrase? in
            let parts = draft.wordIDs.compactMap { vocabulary[$0] }
            let answer = draft.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let alternatives = draft.alternatives.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard (2...4).contains(parts.count), parts.count == draft.wordIDs.count, Set(draft.wordIDs).count >= 2,
                  draft.between.count == parts.count - 1, draft.between.allSatisfy(allowed.contains),
                  !answer.isEmpty, answer.count <= 240, alternatives.count == 3,
                  alternatives.allSatisfy({ !$0.isEmpty && $0.count <= 240 }),
                  Set(([answer] + alternatives).map(normalized)).count == 4, draft.explanation.count <= 300,
                  parts.allSatisfy({ !$0.japanese.isEmpty && $0.japanese.count <= 80 }) else { return nil }
            func joined(_ key: KeyPath<PhraseWord, String>) -> String {
                parts.enumerated().map { ($0.offset == 0 ? "" : draft.between[$0.offset - 1]) + $0.element[keyPath: key] }.joined()
            }
            let japanese = joined(\.japanese), reading = parts.allSatisfy({ !$0.reading.isEmpty }) ? joined(\.reading) : ""
            guard reading.count <= 240, japanese.count <= 240, seen.insert(normalized(japanese)).inserted else { return nil }
            return ComposedPhrase(japanese: japanese, reading: reading,
                translation: answer, alternatives: alternatives, words: parts, explanation: draft.explanation)
        }.prefix(max(0, min(3, limit))).map { $0 }
    }
    private static func normalized(_ value: String) -> String {
        value.folding(options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
