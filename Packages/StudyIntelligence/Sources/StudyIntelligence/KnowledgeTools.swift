import Foundation
import StudyCore

/// Issued references belong to one model run. A persisted citation never contains image bytes.
public struct KnowledgeCitationRegistry: Sendable {
    private var issued: [String: SourceCitation] = [:]
    public init() {}
    @discardableResult public mutating func issue(source: SourceContext, fingerprint: String,
                                                   fragmentID: String? = nil, snapshotFingerprint: String? = nil) -> SourceCitation {
        let citation = SourceCitation(id: "source_" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)),
                                      source: source, sourceFingerprint: fingerprint, fragmentID: fragmentID,
                                      snapshotFingerprint: snapshotFingerprint)
        issued[citation.id] = citation
        return citation
    }
    public func reference(_ id: String) -> SourceCitation? {
        issued[id.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")]
    }
    public func citations(in text: String) -> [SourceCitation] {
        guard let regex = try? NSRegularExpression(pattern: #"\[\[(source_[A-Za-z0-9]+)\]\]"#) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            let id = String(text[range])
            guard seen.insert(id).inserted else { return nil }
            return issued[id]
        }
    }
    public static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\[\[source_[A-Za-z0-9]+\]\]"#, with: "", options: .regularExpression)
    }
}

/// Same saved index as workspace search, without a model, OCR request, or document hydration.
public actor KnowledgeToolAccess {
    public static let maximumOutputCharacters = 64_000
    private let store: VaultStore
    private var registry = KnowledgeCitationRegistry()
    public init(store: VaultStore) { self.store = store }
    public func citations(in text: String) -> [SourceCitation] { registry.citations(in: text) }

    public func search(query: String, limit: Int? = nil, cursor: String? = nil) async throws -> String {
        guard query.count <= 500, (cursor?.count ?? 0) <= 4096 else { throw StudyError.invalidPath }
        let page = try await store.searchKnowledge(.init(query: query, limit: min(40, max(1, limit ?? 10)), cursor: cursor))
        var hits: [[String: Any]] = []
        for hit in page.hits {
            let ref = registry.issue(source: hit.sourceContext, fingerprint: hit.sourceFingerprint, fragmentID: hit.id)
            hits.append(Self.hitJSON(hit, citation: ref))
        }
        let encoder = JSONEncoder()
        let coverage = try JSONSerialization.jsonObject(with: encoder.encode(page.coverage))
        return try Self.json(["hits": hits, "coverage": coverage, "nextCursor": page.nextCursor.map { $0 as Any } ?? NSNull(),
                              "truncated": page.truncated, "textLimit": 400])
    }

    public func readFragment(_ reference: String) async throws -> String {
        guard reference.count <= 512 else { throw StudyError.invalidPath }
        let issued = registry.reference(reference)
        let fragmentID = issued?.fragmentID ?? reference
        guard let hit = try await store.readKnowledgeFragment(fragmentID),
              issued == nil || (issued?.sourceFingerprint == hit.sourceFingerprint && issued?.source.path == hit.path
                                && issued?.source.pageID == hit.pageID && issued?.source.region == hit.region
                                && issued?.source.text == String(hit.text.prefix(800))) else {
            throw StudyError.staleRevision
        }
        let ref = registry.issue(source: hit.sourceContext, fingerprint: hit.sourceFingerprint, fragmentID: hit.id)
        var result = Self.hitJSON(hit, citation: ref)
        result["text"] = String(hit.text.prefix(12_000)); result["textTruncated"] = hit.text.count > 12_000
        return try Self.json(result)
    }

    public func readDocument(_ path: String) async throws -> (output: String, revision: String) {
        let loaded = try await store.knowledgeDocument(path)
        // Text citations survive chat-only atomic Markdown saves; contentRevision excludes chat.
        let ref = registry.issue(source: .init(path: path, text: String(loaded.content.markdown.prefix(800))),
                                 fingerprint: loaded.content.contentRevision)
        var remaining = 16_000, objectsRemaining = 80
        var objectsTruncated = false
        func bounded(_ value: String) -> String {
            let text = String(value.prefix(max(0, remaining))); remaining -= text.count; return text
        }
        let markdown = bounded(loaded.content.markdown)
        let pages: [[String: Any]] = loaded.content.pages.prefix(40).map { page in
            let visible = page.objects.prefix(min(40, objectsRemaining)); objectsRemaining -= visible.count
            objectsTruncated = objectsTruncated || visible.count < page.objects.count
            return ["id": page.id.uuidString, "title": bounded(String(page.title.prefix(200))),
             "width": page.width.isFinite ? page.width : 0, "height": page.height.isFinite ? page.height : 0,
             "objectCount": page.objects.count,
             "objects": visible.map { object -> [String: Any] in
                let r = object.frame
                let frame: Any = [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite)
                    ? ["x": r.x, "y": r.y, "width": r.width, "height": r.height] as Any : NSNull()
                return ["id": object.id.uuidString, "kind": object.kind.rawValue, "frame": frame,
                        "text": object.kind == .image ? "" : bounded(object.content),
                        "asset": object.kind == .image ? String(object.content.prefix(1024)) : ""]
             }]
        }
        return (try Self.json(["source_ref": ref.id, "revision": loaded.content.contentRevision,
                               "markdown": markdown, "pages": pages, "pageCount": loaded.content.pages.count,
                               "truncated": remaining <= 0 || loaded.content.pages.count > 40 || objectsTruncated,
                               "content": "saved authored text and metadata; OCR is available through search/read_fragment"]), loaded.content.contentRevision)
    }

    public func pageSnapshot(path: String, pageID: String, region: Rect?) async throws -> KnowledgeSourceSnapshot {
        let loaded = try await store.knowledgeDocument(path)
        let id: UUID
        if pageID.isEmpty {
            guard let first = loaded.content.pages.first?.id else { throw StudyError.missingPage }; id = first
        } else {
            guard let parsed = UUID(uuidString: pageID) else { throw StudyError.missingPage }; id = parsed
        }
        return try await store.knowledgeSnapshot(path, pageID: id, region: region, includeAssets: true)
    }
    public func citeImage(_ snapshot: KnowledgeSourceSnapshot) async throws -> String {
        guard try await store.validateKnowledgeSnapshot(snapshot) else { throw StudyError.staleRevision }
        let ref = registry.issue(source: snapshot.source, fingerprint: snapshot.sourceFingerprint, snapshotFingerprint: snapshot.fingerprint)
        return try Self.json(["source_ref": ref.id, "path": snapshot.source.path, "pageID": snapshot.source.pageID?.uuidString ?? "",
                              "rendering": "saved ink, images and authored cards on white; no paper pattern; no OCR"])
    }
    public static func validate(_ citation: SourceCitation, store: VaultStore) async throws -> SourceContext {
        if let id = citation.fragmentID {
            guard let hit = try await store.readKnowledgeFragment(id), hit.sourceFingerprint == citation.sourceFingerprint,
                  hit.path == citation.source.path, hit.pageID == citation.source.pageID, hit.region == citation.source.region,
                  String(hit.text.prefix(800)) == citation.source.text else {
                throw StudyError.staleRevision
            }
        } else if let fingerprint = citation.snapshotFingerprint {
            let source = citation.source
            let snapshot = try await store.knowledgeSnapshot(source.path, pageID: source.pageID, region: source.region, includeAssets: true)
            guard snapshot.sourceFingerprint == citation.sourceFingerprint, snapshot.fingerprint == fingerprint else {
                throw StudyError.staleRevision
            }
        } else {
            guard citation.source.pageID == nil, citation.source.region == nil,
                  try await store.knowledgeDocument(citation.source.path).content.contentRevision == citation.sourceFingerprint else {
                throw StudyError.staleRevision
            }
        }
        return citation.source
    }
    private static func hitJSON(_ hit: KnowledgeSearchHit, citation: SourceCitation) -> [String: Any] {
        var result: [String: Any] = ["source_ref": citation.id, "fragmentID": hit.id, "path": String(hit.path.prefix(1024)),
                                    "pathTruncated": hit.path.count > 1024, "text": String(hit.text.prefix(400)),
                                    "textTruncated": hit.text.count > 400, "provenance": hit.provenance.rawValue,
                                    "sourceFingerprint": hit.sourceFingerprint, "pageID": hit.pageID.map { $0.uuidString as Any } ?? NSNull(),
                                    "language": hit.language.map { $0 as Any } ?? NSNull(), "confidence": hit.confidence.map { $0 as Any } ?? NSNull()]
        if let r = hit.region { result["region"] = ["x": r.x, "y": r.y, "width": r.width, "height": r.height] }
        return result
    }
    private static func json(_ object: [String: Any]) throws -> String {
        let value = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        guard value.count <= maximumOutputCharacters else { throw StudyError.modelUnavailable("Knowledge tool output exceeds its limit; request fewer results.") }
        return value
    }
}
