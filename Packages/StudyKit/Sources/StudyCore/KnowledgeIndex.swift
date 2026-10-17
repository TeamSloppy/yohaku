import Foundation
import CryptoKit
import SQLite3

public enum KnowledgeIndexError: Error, Equatable {
    case database(String), unsupportedSchema(Int), invalidPath, invalidFragment, invalidCursor, staleCursor, staleSource
}

/// A synchronous connection, confined to its owning VaultStore actor. Never pass this object across actors.
public final class KnowledgeIndex {
    private var database: OpaquePointer?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
    }()
    private let decoder = JSONDecoder()
    private struct Cursor: Codable {
        let version: Int
        let query: String
        let generation: Int64
        let path: String
        let id: String
    }
    private enum Value { case text(String), integer(Int64) }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open index"
            sqlite3_close(database); database = nil
            throw KnowledgeIndexError.database(message)
        }
        do {
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA foreign_keys = ON")
            var version = 0
            try rows("PRAGMA user_version") { version = Int(sqlite3_column_int($0, 0)) }
            guard version == 0 || version == 1 else { throw KnowledgeIndexError.unsupportedSchema(version) }
            try execute("""
                CREATE TABLE IF NOT EXISTS metadata (generation INTEGER NOT NULL);
                INSERT INTO metadata SELECT 0 WHERE NOT EXISTS (SELECT 1 FROM metadata);
                CREATE TABLE IF NOT EXISTS sources (
                    path TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, raw TEXT NOT NULL, ocr TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS fragments (
                    id TEXT PRIMARY KEY, path TEXT NOT NULL REFERENCES sources(path) ON DELETE CASCADE,
                    provenance TEXT NOT NULL, normalized TEXT NOT NULL, payload TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS fragments_path ON fragments(path);
                CREATE VIRTUAL TABLE IF NOT EXISTS terms USING fts5(words, tokenize='unicode61');
                CREATE TRIGGER IF NOT EXISTS fragments_delete AFTER DELETE ON fragments BEGIN
                    DELETE FROM terms WHERE rowid = old.rowid;
                END;
                PRAGMA user_version = 1;
                """)
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    deinit { sqlite3_close(database) }

    public static func normalizedPath(_ path: String) throws -> String {
        guard !path.hasPrefix("/"), !path.contains("\0") else { throw KnowledgeIndexError.invalidPath }
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                guard !parts.isEmpty else { throw KnowledgeIndexError.invalidPath }
                parts.removeLast()
            } else { parts.append(part) }
        }
        guard !parts.isEmpty else { throw KnowledgeIndexError.invalidPath }
        return parts.joined(separator: "/").precomposedStringWithCanonicalMapping
    }

    /// Replaces raw text atomically. Unchanged fingerprints retain independently captured OCR.
    public func replaceSource(path: String, documentID: UUID? = nil, sourceFingerprint: String,
                              fragments: [KnowledgeSearchHit], rawState: KnowledgeContentState = .complete,
                              ocrState: KnowledgeContentState = .notRequested) throws {
        let path = try Self.normalizedPath(path)
        try transaction {
            var previous: (String, String)?
            try rows("SELECT fingerprint, ocr FROM sources WHERE path = ?", [.text(path)]) { previous = (string($0, 0), string($0, 1)) }
            let unchanged = previous?.0 == sourceFingerprint && rawState != .unavailable
            try execute("""
                INSERT INTO sources VALUES (?, ?, ?, ?) ON CONFLICT(path) DO UPDATE SET
                fingerprint=excluded.fingerprint, raw=excluded.raw, ocr=excluded.ocr
                """, [.text(path), .text(sourceFingerprint), .text(rawState.rawValue), .text(unchanged ? previous!.1 : ocrState.rawValue)])
            try execute("DELETE FROM fragments WHERE path = ? AND (? = 0 OR provenance != 'ocr')", [.text(path), .integer(unchanged ? 1 : 0)])
            try insert(.init(id: "filename", path: path, text: (path as NSString).lastPathComponent,
                             provenance: .filename, sourceFingerprint: sourceFingerprint))
            if rawState != .unavailable {
                for fragment in fragments {
                    guard fragment.provenance == .raw else { throw KnowledgeIndexError.invalidFragment }
                    try validate(fragment, path: path, fingerprint: sourceFingerprint)
                    try insert(fragment)
                }
            }
        }
    }

    /// A bounded crop replaces only intersecting OCR on its page. Nil region replaces the whole page.
    public func replaceRecognition(path: String, sourceFingerprint: String, pageID: UUID, region: Rect? = nil,
                                   fragments: [KnowledgeSearchHit], state: KnowledgeContentState = .partial) throws {
        let path = try Self.normalizedPath(path)
        guard region.map(Self.validRegion) ?? true, region == nil || state != .complete else { throw KnowledgeIndexError.invalidFragment }
        try transaction {
            var current: String?
            try rows("SELECT fingerprint FROM sources WHERE path = ? AND raw != 'unavailable'", [.text(path)]) { current = string($0, 0) }
            guard current == sourceFingerprint else { throw KnowledgeIndexError.staleSource }
            var removed: [String] = []
            try rows("SELECT id, payload FROM fragments WHERE path = ? AND provenance = 'ocr'", [.text(path)]) {
                let hit = try decodeHit(string($0, 1))
                if hit.pageID == pageID, region == nil || hit.region == nil || region!.intersects(hit.region!) { removed.append(string($0, 0)) }
            }
            for id in removed { try execute("DELETE FROM fragments WHERE id = ?", [.text(id)]) }
            for fragment in fragments {
                guard fragment.provenance == .ocr, fragment.pageID == pageID else { throw KnowledgeIndexError.invalidFragment }
                try validate(fragment, path: path, fingerprint: sourceFingerprint)
                try insert(fragment)
            }
            try execute("UPDATE sources SET ocr = ? WHERE path = ?", [.text(state.rawValue), .text(path)])
        }
    }

    public func markUnavailable(path: String) throws {
        try replaceSource(path: path, sourceFingerprint: "", fragments: [], rawState: .unavailable, ocrState: .unavailable)
    }
    public func removeSource(path: String) throws {
        let path = try Self.normalizedPath(path)
        try transaction { try execute("DELETE FROM sources WHERE path = ?", [.text(path)]) }
    }
    public func removeSources(exceptPaths paths: [String]) throws {
        let retained = try Set(paths.map(Self.normalizedPath))
        try transaction {
            var removed: [String] = []
            try rows("SELECT path FROM sources") { if !retained.contains(string($0, 0)) { removed.append(string($0, 0)) } }
            for path in removed { try execute("DELETE FROM sources WHERE path = ?", [.text(path)]) }
        }
    }
    /// Clears this disposable local cache; the caller supplies fresh snapshots afterwards.
    public func rebuild() throws { try transaction { try execute("DELETE FROM sources") } }

    public func fragment(id: String) throws -> KnowledgeSearchHit? {
        var hit: KnowledgeSearchHit?
        try rows("SELECT payload FROM fragments WHERE id = ?", [.text(id)]) { hit = try decodeHit(string($0, 0)) }
        return hit
    }

    public func search(_ request: KnowledgeSearchRequest) throws -> KnowledgeSearchPage {
        let query = KnowledgeTokenizer.normalize(request.query.trimmingCharacters(in: .whitespacesAndNewlines))
        let coverage = try coverage()
        let digest = Self.digest(query)
        var lastPath = "", lastID = ""
        if let encoded = request.cursor {
            guard let data = Data(base64Encoded: encoded), let cursor = try? decoder.decode(Cursor.self, from: data),
                  cursor.version == 1, cursor.query == digest else { throw KnowledgeIndexError.invalidCursor }
            guard cursor.generation == coverage.generation else { throw KnowledgeIndexError.staleCursor }
            lastPath = cursor.path; lastID = cursor.id
        }
        let words = KnowledgeTokenizer.tokens(in: query).map { "\"" + $0.text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let match = words.isEmpty ? "\"__yohaku_empty_term__\"" : words.joined(separator: " AND ")
        var hits: [KnowledgeSearchHit] = []
        // FTS supplies lexical candidates; literal verification/fallback retains CJK substrings.
        try rows("""
            SELECT payload FROM fragments WHERE
            (path > ? OR (path = ? AND id > ?)) AND
            ((? = '' AND provenance = 'filename') OR
             (? != '' AND (rowid IN (SELECT rowid FROM terms WHERE terms MATCH ?) OR instr(normalized, ?) > 0)
              AND instr(normalized, ?) > 0))
            ORDER BY path, id LIMIT ?
            """, [.text(lastPath), .text(lastPath), .text(lastID), .text(query), .text(query), .text(match),
                   .text(query), .text(query), .integer(Int64(min(100, max(1, request.limit)) + 1))]) {
            hits.append(try decodeHit(string($0, 0)))
        }
        let truncated = hits.count > min(100, max(1, request.limit))
        if truncated { hits.removeLast() }
        let cursor: String?
        if truncated, let last = hits.last {
            cursor = try encoder.encode(Cursor(version: 1, query: digest, generation: coverage.generation, path: last.path, id: last.id)).base64EncodedString()
        } else { cursor = nil }
        return .init(hits: hits, coverage: coverage, nextCursor: cursor, truncated: truncated)
    }

    private func coverage() throws -> KnowledgeSearchCoverage {
        var raw: [String: Int] = [:], ocr: [String: Int] = [:], count = 0
        try rows("SELECT raw, ocr, COUNT(*) FROM sources GROUP BY raw, ocr") {
            let n = Int(sqlite3_column_int($0, 2)); count += n
            raw[string($0, 0), default: 0] += n; ocr[string($0, 1), default: 0] += n
        }
        var generation: Int64 = 0
        try rows("SELECT generation FROM metadata") { generation = sqlite3_column_int64($0, 0) }
        return .init(sourceCount: count, raw: raw, ocr: ocr, generation: generation)
    }
    private func validate(_ hit: KnowledgeSearchHit, path: String, fingerprint: String) throws {
        guard try Self.normalizedPath(hit.path) == path, hit.sourceFingerprint == fingerprint,
              hit.confidence.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              hit.region.map(Self.validRegion) ?? true
        else { throw KnowledgeIndexError.invalidFragment }
        let length = hit.text.utf16.count
        for token in hit.tokens {
            guard token.utf16Location >= 0, token.utf16Location <= length, token.utf16Length > 0,
                  token.utf16Length <= length - token.utf16Location,
                  let range = Range(NSRange(location: token.utf16Location, length: token.utf16Length), in: hit.text),
                  hit.text[range] == token.text else { throw KnowledgeIndexError.invalidFragment }
        }
    }
    private static func validRegion(_ region: Rect) -> Bool {
        [region.x, region.y, region.width, region.height, region.x + region.width, region.y + region.height].allSatisfy(\.isFinite)
            && region.width > 0 && region.height > 0
    }
    private func insert(_ hit: KnowledgeSearchHit) throws {
        let path = try Self.normalizedPath(hit.path)
        let id = Self.digest(path + "\0" + hit.provenance.rawValue + "\0" + hit.id)
        let stored = KnowledgeSearchHit(id: id, path: path, pageID: hit.pageID, region: hit.region, text: hit.text,
                                       snippet: hit.snippet, provenance: hit.provenance, sourceFingerprint: hit.sourceFingerprint,
                                       language: hit.language, confidence: hit.confidence, tokens: hit.tokens,
                                       runFingerprint: hit.runFingerprint, engineFingerprint: hit.engineFingerprint)
        let payload = String(decoding: try encoder.encode(stored), as: UTF8.self)
        try execute("INSERT INTO fragments(id, path, provenance, normalized, payload) VALUES (?, ?, ?, ?, ?)",
                    [.text(id), .text(path), .text(hit.provenance.rawValue), .text(KnowledgeTokenizer.normalize(hit.text)), .text(payload)])
        let row = sqlite3_last_insert_rowid(database)
        let terms = hit.tokens.map { KnowledgeTokenizer.normalize($0.text) }.joined(separator: " ")
        try execute("INSERT INTO terms(rowid, words) VALUES (?, ?)", [.integer(row), .text(terms)])
    }
    private static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func decodeHit(_ json: String) throws -> KnowledgeSearchHit { try decoder.decode(KnowledgeSearchHit.self, from: Data(json.utf8)) }
    private func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, column), count: Int(sqlite3_column_bytes(statement, column))), as: UTF8.self)
    }
    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try body(); try execute("UPDATE metadata SET generation = generation + 1"); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func execute(_ sql: String, _ values: [Value] = []) throws {
        // Multi-statement SQL is exclusively the fixed schema literal above; values always use bindings.
        if values.isEmpty {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
        } else { try rows(sql, values) { _ in } }
    }
    private func rows(_ sql: String, _ values: [Value] = [], body: (OpaquePointer) throws -> Void) throws {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let statement = pointer else { throw failure() }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let result: Int32
            switch value {
            case .text(let text):
                result = text.withCString { sqlite3_bind_text(statement, Int32(offset + 1), $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let integer): result = sqlite3_bind_int64(statement, Int32(offset + 1), integer)
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW { try body(statement); result = sqlite3_step(statement) }
        guard result == SQLITE_DONE else { throw failure() }
    }
    private func failure() -> KnowledgeIndexError { .database(String(cString: sqlite3_errmsg(database))) }
}
