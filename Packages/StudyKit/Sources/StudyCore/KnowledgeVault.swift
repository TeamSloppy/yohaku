import Foundation
import CryptoKit

struct KnowledgeReceipt: Codable {
    var pageID: UUID
    var region: Rect?
    var fingerprint: String
    var identity: String
    var ids: Set<String>
}

struct KnowledgeSourceRecord: Codable {
    var path: String
    var identity: String
    var fingerprint: String
    var receipts: [KnowledgeReceipt] = []
}

struct KnowledgeVaultState {
    var index: KnowledgeIndex?
    var directory: URL?
    var records: [String: KnowledgeSourceRecord] = [:]
    var reconciled = false
}

private struct KnowledgeValidationCache {
    var sources: [String: KnowledgeSourceSnapshot] = [:]
    var invalidPaths = Set<String>()
    var receipts: [String: Bool] = [:]
}

extension VaultStore {
    /// Local disposable cache. Never create database, WAL, or receipts inside the vault.
    func openKnowledgeIndex() throws -> KnowledgeIndex {
        if let index = knowledgeState.index { return index }
        let fm = FileManager.default
        let base = try knowledgeIndexDirectory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            .appendingPathComponent("Yohaku/Knowledge", isDirectory: true)
        let namespace = knowledgeDigest(root.path + "\0" + (try identifier()))
        let directory = base.appendingPathComponent(namespace, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        guard directory != root, !directory.path.hasPrefix(root.path + "/") else { throw StudyError.invalidPath }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard !fm.isUbiquitousItem(at: directory) else { throw StudyError.invalidPath }
        knowledgeState.directory = directory
        let receiptURL = directory.appendingPathComponent("receipts.json")
        if fm.fileExists(atPath: receiptURL.path) {
            knowledgeState.records = try JSONDecoder().decode([String: KnowledgeSourceRecord].self, from: Data(contentsOf: receiptURL))
        }
        let index = try KnowledgeIndex(url: directory.appendingPathComponent("knowledge.sqlite"))
        knowledgeState.index = index
        return index
    }

    private func persistKnowledgeRecords() throws {
        guard let directory = knowledgeState.directory else { throw KnowledgeIndexError.database("Index unavailable") }
        try JSONEncoder().encode(knowledgeState.records).write(to: directory.appendingPathComponent("receipts.json"), options: .atomic)
    }

    /// Explicit refresh for file-presenter/external changes; reads saved raw text without repair or hydration.
    public func reconcileKnowledge() throws {
        do {
            let index = try openKnowledgeIndex()
            let paths = try list().filter { !$0.isDirectory }.map(\.path)
            try index.removeSources(exceptPaths: paths)
            let retained = try Set(paths.map(KnowledgeIndex.normalizedPath))
            knowledgeState.records = knowledgeState.records.filter { retained.contains($0.key) }
            for path in paths { try refreshKnowledgeSource(path, index: index) }
            try persistKnowledgeRecords()
            knowledgeState.reconciled = true
            setKnowledgeError(nil)
        } catch {
            knowledgeState.reconciled = false
            setKnowledgeError(String(describing: error))
            throw error
        }
    }

    public func rebuildKnowledge() throws {
        // Broken receipts and unsupported schemas are recoverable because this is a local cache.
        if knowledgeState.directory == nil {
            do { _ = try openKnowledgeIndex() }
            catch { guard knowledgeState.directory != nil else { throw error } }
        }
        knowledgeState.index = nil
        if let directory = knowledgeState.directory {
            try FileManager.default.removeItem(at: directory)
        }
        knowledgeState = .init()
        try reconcileKnowledge()
    }

    /// File persistence has already succeeded. Cache failures never turn a successful save into a conflict.
    func knowledgeDidChange(_ path: String? = nil) {
        guard let index = knowledgeState.index else { knowledgeState.reconciled = false; return }
        do {
            if let path { try refreshKnowledgeSource(path, index: index); try persistKnowledgeRecords() }
            else { try reconcileKnowledge() }
        } catch {
            knowledgeState.reconciled = false
            setKnowledgeError(String(describing: error))
        }
    }

    private func refreshKnowledgeSource(_ path: String, index: KnowledgeIndex) throws {
        let key = try KnowledgeIndex.normalizedPath(path)
        let snapshot: KnowledgeSourceSnapshot
        do { snapshot = try knowledgeSnapshot(path) }
        catch {
            // Keep a discoverable filename, but never old text for an unreadable/cloud-only source.
            try index.markUnavailable(path: path)
            knowledgeState.records.removeValue(forKey: key)
            return
        }
        let previous = knowledgeState.records[key]
        if previous?.identity != snapshot.sourceIdentity {
            try index.removeSource(path: path)
        }
        let unchanged = previous?.identity == snapshot.sourceIdentity && previous?.fingerprint == snapshot.sourceFingerprint
        var fragments: [KnowledgeSearchHit] = []
        func append(_ text: String, id: String, pageID: UUID? = nil, region: Rect? = nil) {
            guard !text.isEmpty else { return }
            fragments.append(.init(id: id, path: path, pageID: pageID, region: region, text: text,
                                   sourceFingerprint: snapshot.sourceFingerprint))
        }
        append(path, id: "path")
        append(snapshot.content.markdown, id: "markdown")
        for page in snapshot.content.pages {
            append(page.title, id: "title-\(page.id)", pageID: page.id)
            for object in page.objects {
                append(object.content, id: object.id.uuidString, pageID: page.id, region: object.frame)
            }
        }
        try index.replaceSource(path: path, documentID: snapshot.content.id, sourceFingerprint: snapshot.sourceFingerprint,
                                fragments: fragments, rawState: fragments.isEmpty ? .empty : .complete)
        knowledgeState.records[key] = .init(path: path, identity: snapshot.sourceIdentity, fingerprint: snapshot.sourceFingerprint,
                                             receipts: unchanged ? previous!.receipts : [])
    }

    public func searchKnowledge(_ request: KnowledgeSearchRequest) throws -> KnowledgeSearchPage {
        try Task.checkCancellation()
        if !knowledgeState.reconciled { try reconcileKnowledge() }
        let index = try openKnowledgeIndex()
        let page = try index.search(request)
        // Validate only candidates, not every source for every keystroke. Refresh discovers new matches.
        var stalePaths = Set<String>()
        var validation = KnowledgeValidationCache()
        for hit in page.hits where !(try currentKnowledgeHit(hit, cache: &validation)) { stalePaths.insert(hit.path) }
        guard !stalePaths.isEmpty else { return page }
        for path in stalePaths {
            // Asset/identity changes must clear OCR even when manifest contentRevision is unchanged.
            try index.removeSource(path: path)
            knowledgeState.records.removeValue(forKey: path)
            if FileManager.default.fileExists(atPath: try fileURL(path).path) { try refreshKnowledgeSource(path, index: index) }
        }
        try persistKnowledgeRecords()
        if request.cursor != nil { throw KnowledgeIndexError.staleCursor }
        return try searchKnowledge(request)
    }

    public func readKnowledgeFragment(_ id: String) throws -> KnowledgeSearchHit? {
        if !knowledgeState.reconciled { try reconcileKnowledge() }
        var validation = KnowledgeValidationCache()
        guard let hit = try openKnowledgeIndex().fragment(id: id), try currentKnowledgeHit(hit, cache: &validation) else { return nil }
        return hit
    }

    private func currentKnowledgeHit(_ hit: KnowledgeSearchHit, cache: inout KnowledgeValidationCache) throws -> Bool {
        // Unavailable rows deliberately expose only a filename.
        if hit.provenance == .filename, hit.sourceFingerprint.isEmpty {
            return FileManager.default.fileExists(atPath: try fileURL(hit.path).path)
        }
        guard let record = knowledgeState.records[hit.path] else { return false }
        if cache.sources[hit.path] == nil, !cache.invalidPaths.contains(hit.path) {
            if let source = try? knowledgeSnapshot(record.path) { cache.sources[hit.path] = source }
            else { cache.invalidPaths.insert(hit.path) }
        }
        guard let snapshot = cache.sources[hit.path], snapshot.sourceFingerprint == hit.sourceFingerprint,
              record.identity == snapshot.sourceIdentity else { return false }
        guard hit.provenance == .ocr else { return true }
        guard let receipt = record.receipts.first(where: { $0.ids.contains(hit.id) }),
              let crop = receipt.region, let region = hit.region,
              region.x >= crop.x, region.y >= crop.y,
              region.x + region.width <= crop.x + crop.width,
              region.y + region.height <= crop.y + crop.height else { return false }
        let key = receipt.identity + receipt.fingerprint
        if let valid = cache.receipts[key] { return valid }
        let current = try? knowledgeSnapshot(record.path, pageID: receipt.pageID, region: receipt.region, includeAssets: true)
        let valid = current?.hasCompleteAssets == true && current?.fingerprint == receipt.fingerprint && current?.sourceIdentity == receipt.identity
        cache.receipts[key] = valid
        return valid
    }

    /// Capture, recognition, and validation stay separate; this final actor turn has no suspension point.
    public func commitRecognition(_ fragments: [KnowledgeSearchHit], matching snapshot: KnowledgeSourceSnapshot,
                                  state: KnowledgeContentState = .partial) throws {
        try Task.checkCancellation()
        guard snapshot.includesAssets, snapshot.hasCompleteAssets,
              let pageID = snapshot.source.pageID, let crop = snapshot.source.region,
              try validateKnowledgeSnapshot(snapshot) else { throw KnowledgeIndexError.staleSource }
        guard fragments.allSatisfy({ hit in
            hit.provenance == .ocr && hit.path == snapshot.source.path && hit.pageID == pageID
                && hit.sourceFingerprint == snapshot.sourceFingerprint
                && hit.region.map({ region in
                    region.x >= crop.x && region.y >= crop.y && region.x + region.width <= crop.x + crop.width
                        && region.y + region.height <= crop.y + crop.height
                }) == true
        }) else { throw KnowledgeIndexError.invalidFragment }
        let index = try openKnowledgeIndex()
        let path = try KnowledgeIndex.normalizedPath(snapshot.source.path)
        try refreshKnowledgeSource(snapshot.source.path, index: index)
        // Recheck captured bytes after cache preparation, then synchronously compare the index's global fingerprint and write.
        guard try validateKnowledgeSnapshot(snapshot) else { throw KnowledgeIndexError.staleSource }
        try Task.checkCancellation()
        let page = snapshot.content.pages.first { $0.id == pageID }!
        let wholePage = snapshot.content.kind == .notebook && crop == Rect(x: 0, y: 0, width: page.width, height: page.height)
        let region = wholePage ? nil : crop
        // A manual page/crop run cannot establish whole-document completeness.
        let scopedState: KnowledgeContentState = state == .complete ? .partial : state
        try index.replaceRecognition(path: snapshot.source.path, sourceFingerprint: snapshot.sourceFingerprint,
                                     pageID: pageID, region: region, fragments: fragments, state: scopedState)
        let ids = Set(fragments.map { knowledgeDigest(path + "\0ocr\0" + $0.id) })
        let receipt = KnowledgeReceipt(pageID: pageID, region: crop, fingerprint: snapshot.fingerprint,
                                       identity: snapshot.sourceIdentity, ids: ids)
        for offset in knowledgeState.records[path]!.receipts.indices {
            let existing = knowledgeState.records[path]!.receipts[offset].ids
            knowledgeState.records[path]!.receipts[offset].ids = try Set(existing.filter { id in
                guard !ids.contains(id) else { return false }
                return try index.fragment(id: id) != nil
            })
        }
        knowledgeState.records[path]!.receipts.removeAll { $0.ids.isEmpty }
        knowledgeState.records[path]!.receipts.append(receipt)
        do { try persistKnowledgeRecords() }
        catch {
            // Fail closed if a durable receipt cannot accompany the derived rows.
            try? index.removeSource(path: snapshot.source.path)
            knowledgeState.records.removeValue(forKey: path)
            knowledgeState.reconciled = false
            setKnowledgeError(String(describing: error))
            throw error
        }
    }

    private func knowledgeDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
