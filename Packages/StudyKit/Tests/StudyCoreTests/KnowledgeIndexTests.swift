import Foundation
import Testing
@testable import StudyCore

struct KnowledgeIndexTests {
    private func databaseURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KnowledgeTests-\(UUID())/knowledge.sqlite")
    }
    private func raw(_ text: String, path: String = "Note.md", fingerprint: String = "v1", id: String = "raw") -> KnowledgeSearchHit {
        .init(id: id, path: path, text: text, sourceFingerprint: fingerprint)
    }
    @Test func multilingualLiteralSearchAndUntrustedSyntax() throws {
        let url = databaseURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = try KnowledgeIndex(url: url)
        let text = "東京で日本語を勉強しています。 ПРИВЕТ мир! Ｈｅｌｌｏ café \"quoted\" OR * - : ; DROP TABLE sources; --"
        try index.replaceSource(path: "Note.md", sourceFingerprint: "v1", fragments: [raw(text)])
        for query in ["日本語を勉", "привет", "hello", "\"quoted\"", "OR * - :", "; DROP TABLE sources; --", "* - :"] {
            #expect(try index.search(.init(query: query)).hits.map(\.text) == [text])
        }
        #expect(try index.search(.init(query: "нет такого")).hits.isEmpty)
        let tokens = KnowledgeTokenizer.tokens(in: "😀 Привет 東京", language: "ru")
        for token in tokens {
            #expect(("😀 Привет 東京" as NSString).substring(with: NSRange(location: token.utf16Location, length: token.utf16Length)) == token.text)
        }
        #expect(tokens.first(where: { $0.text == "Привет" })?.utf16Location == 3)
    }
    @Test func replacementRollsBackAndPathsDoNotAliasDocumentUUID() throws {
        let url = databaseURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = try KnowledgeIndex(url: url), uuid = UUID()
        try index.replaceSource(path: "./Note.md", documentID: uuid, sourceFingerprint: "v1", fragments: [raw("before")])
        try index.replaceSource(path: "Copy.md", documentID: uuid, sourceFingerprint: "v1", fragments: [raw("copied contents", path: "Copy.md")])
        let generation = try index.search(.init(query: "")).coverage.generation
        #expect(throws: KnowledgeIndexError.invalidFragment) {
            try index.replaceSource(path: "Note.md", sourceFingerprint: "v2", fragments: [
                raw("new", fingerprint: "v2"), raw("bad", path: "Elsewhere.md", fingerprint: "v2", id: "bad")
            ])
        }
        #expect(try index.search(.init(query: "before")).hits.count == 1)
        #expect(try index.search(.init(query: "new")).hits.isEmpty)
        #expect(try index.search(.init(query: "")).coverage.generation == generation)
        try index.removeSource(path: "Note.md")
        #expect(try index.search(.init(query: "copied contents")).hits.map(\.path) == ["Copy.md"])
        #expect(throws: KnowledgeIndexError.invalidPath) { try index.removeSource(path: "../escape.md") }
    }
    @Test func cursorsBindQueryAndGenerationAndPaginationHasNoDuplicates() throws {
        let url = databaseURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = try KnowledgeIndex(url: url)
        for path in ["A.md", "B.md", "C.md"] {
            try index.replaceSource(path: path, sourceFingerprint: "v1", fragments: [raw("match", path: path)])
        }
        let first = try index.search(.init(query: "match", limit: 1))
        let cursor = try #require(first.nextCursor)
        let second = try index.search(.init(query: "match", limit: 1, cursor: cursor))
        let third = try index.search(.init(query: "match", limit: 1, cursor: second.nextCursor))
        #expect(first.truncated && second.truncated && !third.truncated)
        #expect((first.hits + second.hits + third.hits).map(\.path) == ["A.md", "B.md", "C.md"])
        #expect(throws: KnowledgeIndexError.invalidCursor) { try index.search(.init(query: "other", cursor: cursor)) }
        #expect(throws: KnowledgeIndexError.invalidCursor) { try index.search(.init(query: "match", cursor: "malformed")) }
        try index.removeSource(path: "B.md")
        #expect(throws: KnowledgeIndexError.staleCursor) { try index.search(.init(query: "match", cursor: cursor)) }
        #expect(KnowledgeSearchRequest(query: "", limit: 900).limit == 100)
    }
    @Test func recognitionPreservesOtherPagesAndDisjointRegionsThenInvalidatesOnRawChange() throws {
        let url = databaseURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let index = try KnowledgeIndex(url: url), page = UUID(), other = UUID()
        try index.replaceSource(path: "Note.md", sourceFingerprint: "v1", fragments: [raw("raw")])
        func recognize(_ id: String, _ target: UUID, _ x: Double) throws {
            let rect = Rect(x: x, y: -50, width: 10, height: 10)
            let hit = KnowledgeSearchHit(id: id, path: "Note.md", pageID: target, region: rect, text: "ocr \(id)",
                                         provenance: .ocr, sourceFingerprint: "v1", language: "ja", confidence: 0.9, runFingerprint: id)
            try index.replaceRecognition(path: "Note.md", sourceFingerprint: "v1", pageID: target, region: rect, fragments: [hit])
        }
        try recognize("left", page, -100); try recognize("right", page, 100); try recognize("other", other, -100)
        try recognize("replacement", page, -100)
        #expect(try index.search(.init(query: "ocr")).hits.count == 3)
        #expect(try index.search(.init(query: "left")).hits.isEmpty)
        try index.replaceSource(path: "Note.md", sourceFingerprint: "v1", fragments: [raw("raw refreshed")])
        #expect(try index.search(.init(query: "ocr")).hits.count == 3)
        #expect(try index.search(.init(query: "")).coverage.ocr["partial"] == 1)
        try index.replaceRecognition(path: "Note.md", sourceFingerprint: "v1", pageID: page, fragments: [])
        #expect(try index.search(.init(query: "ocr")).hits.map(\.pageID) == [other])
        #expect(throws: KnowledgeIndexError.invalidFragment) {
            try index.replaceRecognition(path: "Note.md", sourceFingerprint: "v1", pageID: page,
                                         region: Rect(x: 0, y: 0), fragments: [], state: .complete)
        }
        try index.replaceSource(path: "Note.md", sourceFingerprint: "v2", fragments: [raw("raw changed", fingerprint: "v2")])
        #expect(try index.search(.init(query: "ocr")).hits.isEmpty)
        #expect(throws: KnowledgeIndexError.staleSource) { try recognize("stale", page, 0) }
    }
    @Test func unavailableNamesCoverageReopenAndRebuild() throws {
        let url = databaseURL(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let index = try KnowledgeIndex(url: url)
            try index.replaceSource(path: "Cloud.md", sourceFingerprint: "v1", fragments: [raw("private old text", path: "Cloud.md")])
            try index.markUnavailable(path: "Cloud.md")
            #expect(try index.search(.init(query: "private")).hits.isEmpty)
            #expect(try index.search(.init(query: "cloud")).hits.first?.provenance == .filename)
            let coverage = try index.search(.init(query: "")).coverage
            #expect(coverage.raw["unavailable"] == 1 && coverage.ocr["unavailable"] == 1)
        }
        let reopened = try KnowledgeIndex(url: url)
        #expect(try reopened.search(.init(query: "")).hits.map(\.path) == ["Cloud.md"])
        try reopened.removeSources(exceptPaths: [])
        #expect(try reopened.search(.init(query: "")).coverage.sourceCount == 0)
        try reopened.replaceSource(path: "Note.md", sourceFingerprint: "v1", fragments: [raw("rebuilt")])
        let hit = try #require(reopened.search(.init(query: "rebuilt")).hits.first)
        #expect(try reopened.fragment(id: hit.id) == hit)
        try reopened.rebuild()
        #expect(try reopened.fragment(id: hit.id) == nil)
        #expect(try reopened.search(.init(query: "")).coverage.sourceCount == 0)
    }
}
