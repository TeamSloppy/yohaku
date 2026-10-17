import Foundation
import NaturalLanguage

public enum KnowledgeProvenance: String, Codable, Sendable { case filename, raw, ocr }
public enum KnowledgeContentState: String, Codable, Sendable {
    case complete, partial, pending, notRequested, unavailable, failed, unsupported, empty
}

public struct KnowledgeToken: Codable, Equatable, Sendable {
    public let text: String
    public let utf16Location: Int
    public let utf16Length: Int
    public init(text: String, utf16Location: Int, utf16Length: Int) {
        self.text = text; self.utf16Location = utf16Location; self.utf16Length = utf16Length
    }
}

public enum KnowledgeTokenizer {
    public static func normalize(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    /// Offsets address the original observation, never the normalized search string.
    public static func tokens(in text: String, language: String? = nil) -> [KnowledgeToken] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        if let language { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var result: [KnowledgeToken] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let offset = NSRange(range, in: text)
            result.append(.init(text: String(text[range]), utf16Location: offset.location, utf16Length: offset.length))
            return true
        }
        return result
    }
}

public struct KnowledgeSearchRequest: Codable, Equatable, Sendable {
    public let query: String
    public let limit: Int
    public let cursor: String?
    public init(query: String, limit: Int = 40, cursor: String? = nil) {
        self.query = query; self.limit = min(100, max(1, limit)); self.cursor = cursor
    }
}

public struct KnowledgeSearchHit: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let path: String
    public let pageID: UUID?
    public let region: Rect?
    public let text: String
    public let snippet: String
    public let provenance: KnowledgeProvenance
    public let sourceFingerprint: String
    public let language: String?
    public let confidence: Double?
    public let tokens: [KnowledgeToken]
    public let runFingerprint: String?
    public let engineFingerprint: String?
    public init(id: String = UUID().uuidString, path: String, pageID: UUID? = nil, region: Rect? = nil,
                text: String, snippet: String? = nil, provenance: KnowledgeProvenance = .raw,
                sourceFingerprint: String, language: String? = nil, confidence: Double? = nil,
                tokens: [KnowledgeToken]? = nil, runFingerprint: String? = nil, engineFingerprint: String? = nil) {
        self.id = id; self.path = path; self.pageID = pageID; self.region = region; self.text = text
        self.snippet = snippet ?? String(text.prefix(240)); self.provenance = provenance
        self.sourceFingerprint = sourceFingerprint; self.language = language; self.confidence = confidence
        self.tokens = tokens ?? KnowledgeTokenizer.tokens(in: text, language: language); self.runFingerprint = runFingerprint
        self.engineFingerprint = engineFingerprint
    }
    public var sourceContext: SourceContext { .init(path: path, pageID: pageID, region: region, text: text) }
}

public struct KnowledgeSearchCoverage: Codable, Equatable, Sendable {
    public let sourceCount: Int
    public let raw: [String: Int]
    public let ocr: [String: Int]
    public let generation: Int64
    public init(sourceCount: Int = 0, raw: [String: Int] = [:], ocr: [String: Int] = [:], generation: Int64 = 0) {
        self.sourceCount = sourceCount; self.raw = raw; self.ocr = ocr; self.generation = generation
    }
}

public struct KnowledgeSearchPage: Codable, Equatable, Sendable {
    public let hits: [KnowledgeSearchHit]
    public let coverage: KnowledgeSearchCoverage
    public let nextCursor: String?
    public let truncated: Bool
    public init(hits: [KnowledgeSearchHit], coverage: KnowledgeSearchCoverage = .init(), nextCursor: String? = nil, truncated: Bool = false) {
        self.hits = hits; self.coverage = coverage; self.nextCursor = nextCursor; self.truncated = truncated
    }
}
