import Foundation
import CryptoKit

/// Immutable saved source for local extraction. Asset references are never repaired.
public struct KnowledgeSourceSnapshot: Sendable {
    public let source: SourceContext
    public let content: DocumentContent
    public let assets: [String: Data]
    public let missingAssets: [String]
    public let unavailableAssets: [String]
    /// Whole-document saved content revision, independent of crop and chat.
    public let sourceFingerprint: String
    /// Selection, source revision, captured bytes and missing/unavailable inventory.
    public let fingerprint: String
    public var hasCompleteAssets: Bool { missingAssets.isEmpty && unavailableAssets.isEmpty }
    let includesAssets: Bool
    let sourceIdentity: String

    init(source: SourceContext, content: DocumentContent, assets: [String: Data],
         missingAssets: [String], unavailableAssets: [String], includesAssets: Bool, sourceIdentity: String) throws {
        self.source = source; self.content = content; self.assets = assets
        self.missingAssets = missingAssets.sorted(); self.unavailableAssets = unavailableAssets.sorted()
        self.includesAssets = includesAssets; self.sourceIdentity = sourceIdentity
        sourceFingerprint = content.contentRevision
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = SHA256()
        // Encode variable-length fields with boundaries before hashing asset bytes.
        hash.update(data: try encoder.encode(source))
        hash.update(data: try encoder.encode(sourceIdentity))
        hash.update(data: Data(sourceFingerprint.utf8))
        hash.update(data: try encoder.encode(includesAssets))
        hash.update(data: try encoder.encode(self.missingAssets))
        hash.update(data: try encoder.encode(self.unavailableAssets))
        for name in assets.keys.sorted() {
            hash.update(data: try encoder.encode(name))
            hash.update(data: Data(SHA256.hash(data: assets[name]!)))
        }
        fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum KnowledgeSnapshotError: Error, Equatable, Sendable {
    case sourceUnavailable, invalidRegion, explicitRegionRequired, byteLimitExceeded, assetLimitExceeded
}

enum KnowledgeSnapshotLimits {
    static let bytes = 32 * 1024 * 1024
    static let assets = 256
    static func validate(_ rect: Rect) throws {
        guard [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0, rect.width <= 8192, rect.height <= 8192,
              rect.width * rect.height <= 16_777_216 else { throw KnowledgeSnapshotError.invalidRegion }
    }

    static func selection(content: DocumentContent, pageID: UUID?, region: Rect?, includeAssets: Bool) throws -> (Rect?, Set<String>) {
        if let region { try validate(region) }
        let page = try pageID.map { id in
            guard let page = content.pages.first(where: { $0.id == id }) else { throw StudyError.missingPage }
            return page
        }
        guard includeAssets, content.kind != .markdown else { return (region, []) }
        guard let page else { throw StudyError.missingPage }
        if content.kind == .infinity, region == nil { throw KnowledgeSnapshotError.explicitRegionRequired }
        let crop = region ?? Rect(x: 0, y: 0, width: page.width, height: page.height)
        try validate(crop)
        var names = Set<String>()
        if let legacy = page.drawingFile { names.insert(legacy) }
        // Shard bounds cover complete crossing strokes, not a tile membership key.
        for shard in page.shards {
            guard validBounds(shard.bounds) else { throw KnowledgeSnapshotError.invalidRegion }
            if shard.bounds.intersects(crop) { names.insert(shard.file) }
        }
        for object in page.objects where object.kind == .image {
            guard validBounds(object.frame) else { throw KnowledgeSnapshotError.invalidRegion }
            if object.frame.intersects(crop) { names.insert(object.content) }
        }
        guard names.count <= assets else { throw KnowledgeSnapshotError.assetLimitExceeded }
        return (crop, names)
    }

    private static func validBounds(_ rect: Rect) -> Bool {
        [rect.x, rect.y, rect.width, rect.height, rect.x + rect.width, rect.y + rect.height].allSatisfy(\.isFinite)
            && rect.width >= 0 && rect.height >= 0
    }
}
