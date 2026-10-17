import Foundation
import Testing
@testable import StudyCore

struct KnowledgeVaultTests {
    @Test func indexedLinkAndImageContentRetainsLegacySearchParityAndCoordinates() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await store.create("Objects.studycanvas", kind: .notebook)
        var content = initial.content
        content.pages[0].objects = [
            .init(kind: .link, frame: .init(x: 30, y: 40, width: 120, height: 60), content: "https://example.org/needle-link"),
            .init(kind: .image, frame: .init(x: 200, y: 80, width: 90, height: 70), content: "assets/needle-image.png")
        ]
        _ = try await store.save("Objects.studycanvas", content: content, expectedRevision: initial.revision)
        for object in content.pages[0].objects {
            let query = object.kind == .link ? "needle-link" : "needle-image"
            let indexed = try await store.searchKnowledge(.init(query: query))
            let legacy = try await store.search(query)
            #expect(indexed.hits.map(\.path) == legacy.map(\.path))
            let found = try #require(indexed.hits.first)
            #expect(found.text == object.content)
            #expect(found.provenance == .raw)
            #expect(found.pageID == content.pages[0].id)
            #expect(found.region == object.frame)
        }
    }

    @Test func fallbackReadsRawManifestAndPreservesMissingAssetsAndFilenameMatches() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("Vault/Raw.studycanvas")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        var content = DocumentContent(kind: .infinity)
        content.pages[0].drawingFile = "assets/missing.drawing"
        content.pages[0].shards = [.init(file: "assets/missing-shard.drawing", bounds: .init())]
        content.pages[0].objects = [.init(kind: .text, content: "fallback needle")]
        let bytes = try JSONEncoder().encode(content)
        let manifest = package.appendingPathComponent("manifest.json")
        try bytes.write(to: manifest)
        let missingPackage = directory.appendingPathComponent("Vault/Missing.studycanvas")
        try FileManager.default.createDirectory(at: missingPackage, withIntermediateDirectories: true)
        #expect(try await store.search("fallback needle").map(\.path) == ["Raw.studycanvas"])
        #expect(try await store.search("Missing").map(\.path) == ["Missing.studycanvas"])
        #expect(try await store.search("").count == 2)
        let raw = try await store.knowledgeDocument("Raw.studycanvas")
        #expect(raw.content == content)
        #expect(!raw.needsRepair)
        #expect(try Data(contentsOf: manifest) == bytes)
        #expect(!FileManager.default.fileExists(atPath: package.appendingPathComponent("assets").path))
        #expect(!FileManager.default.fileExists(atPath: missingPackage.appendingPathComponent("manifest.json").path))
        // Ordinary load learns the infinity kind; a raw fallback scan must leave listing metadata untouched.
        #expect(try await store.list().first(where: { $0.path == "Raw.studycanvas" })?.kind == .notebook)
    }

    private func fixture() async throws -> (VaultStore, URL, URL) {
        let directory = URL.temporaryDirectory.appendingPathComponent("KnowledgeVault-\(UUID())")
        let cache = directory.appendingPathComponent("Cache")
        let store = VaultStore(root: directory.appendingPathComponent("Vault"), indexDirectory: cache)
        try await store.prepare()
        return (store, directory, cache)
    }

    private func hit(_ snapshot: KnowledgeSourceSnapshot, text: String = "手書き", id: String = "line") -> KnowledgeSearchHit {
        .init(id: id, path: snapshot.source.path, pageID: snapshot.source.pageID,
              region: snapshot.source.region, text: text, provenance: .ocr,
              sourceFingerprint: snapshot.sourceFingerprint, language: "ja", confidence: 0.9,
              runFingerprint: "manual", engineFingerprint: "test")
    }

    @Test func persistedRawAndOCRSurviveReopenAndChatSave() async throws {
        let (store, directory, cache) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var content = try await store.create("Notes.studycanvas", kind: .notebook).content
        content.pages[0].objects = [.init(kind: .text, content: "saved raw")]
        var loaded = try await store.load("Notes.studycanvas")
        loaded = try await store.save("Notes.studycanvas", content: content, expectedRevision: loaded.revision)
        let snapshot = try await store.knowledgeSnapshot("Notes.studycanvas", pageID: content.pages[0].id, includeAssets: true)
        try await store.commitRecognition([hit(snapshot)], matching: snapshot)
        content.messages.append(.init(role: .user, text: "private chat"))
        _ = try await store.save("Notes.studycanvas", content: content, expectedRevision: loaded.revision)
        let reopened = VaultStore(root: directory.appendingPathComponent("Vault"), indexDirectory: cache)
        #expect(try await reopened.searchKnowledge(.init(query: "saved raw")).hits.count == 1)
        let result = try await reopened.searchKnowledge(.init(query: "手書き"))
        #expect(result.hits.count == 1)
        #expect(result.coverage.ocr["partial"] == 1)
        #expect(try await reopened.readKnowledgeFragment(result.hits[0].id)?.text == "手書き")
        #expect(try await reopened.searchKnowledge(.init(query: "private chat")).hits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("Vault/knowledge.sqlite").path))
    }

    @Test func pathsAndCopiedVaultIdentifiersHaveIndependentNamespaces() async throws {
        let (store, directory, cache) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try await store.create("A.md", kind: .markdown, text: "shared UUID")
        _ = try await store.save("B.md", content: first.content, expectedRevision: nil)
        #expect(try await store.searchKnowledge(.init(query: "shared UUID")).hits.count == 2)
        let copied = directory.appendingPathComponent("Copy")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Vault"), to: copied)
        let other = VaultStore(root: copied, indexDirectory: cache)
        let originalID = try await store.identifier()
        #expect(try await other.identifier() == originalID)
        let old = try await other.load("A.md")
        var edited = old.content; edited.markdown = "different copy"
        _ = try await other.save("A.md", content: edited, expectedRevision: old.revision)
        #expect(try await other.searchKnowledge(.init(query: "different copy")).hits.count == 1)
        #expect(try await store.searchKnowledge(.init(query: "different copy")).hits.isEmpty)
        let namespaces = try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)
        #expect(namespaces.count == 2)
    }

    @Test func renameDeleteAndExternalReplacementInvalidateRowsAndCursors() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.create("A.md", kind: .markdown, text: "needle")
        _ = try await store.create("B.md", kind: .markdown, text: "needle")
        let first = try await store.searchKnowledge(.init(query: "needle", limit: 1))
        let cursor = try #require(first.nextCursor)
        try await store.move("A.md", to: "Renamed.md")
        await #expect(throws: KnowledgeIndexError.staleCursor) {
            try await store.searchKnowledge(.init(query: "needle", limit: 1, cursor: cursor))
        }
        #expect(try await store.searchKnowledge(.init(query: "needle")).hits.map(\.path).sorted() == ["B.md", "Renamed.md"])
        try await store.trash("Renamed.md")
        #expect(try await store.searchKnowledge(.init(query: "needle")).hits.map(\.path) == ["B.md"])
        try Data("external replacement".utf8).write(to: directory.appendingPathComponent("Vault/B.md"), options: .atomic)
        #expect(try await store.searchKnowledge(.init(query: "needle")).hits.isEmpty)
        #expect(try await store.searchKnowledge(.init(query: "external replacement")).hits.count == 1)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("Vault/B.md"))
        try await store.reconcileKnowledge()
        #expect(try await store.searchKnowledge(.init(query: "")).hits.isEmpty)
    }

    @Test func staleCancelledAndIncompleteAssetCommitsAreRejected() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await store.create("Ink.studycanvas", kind: .notebook)
        let pageID = initial.content.pages[0].id
        let snapshot = try await store.knowledgeSnapshot("Ink.studycanvas", pageID: pageID, includeAssets: true)
        var edited = initial.content; edited.pages[0].drawingFile = "assets/missing.drawing"
        _ = try await store.save("Ink.studycanvas", content: edited, expectedRevision: initial.revision)
        await #expect(throws: KnowledgeIndexError.staleSource) { try await store.commitRecognition([hit(snapshot)], matching: snapshot) }
        let incomplete = try await store.knowledgeSnapshot("Ink.studycanvas", pageID: pageID, includeAssets: true)
        #expect(!incomplete.hasCompleteAssets)
        await #expect(throws: KnowledgeIndexError.staleSource) { try await store.commitRecognition([hit(incomplete)], matching: incomplete) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.commitRecognition([hit(snapshot)], matching: snapshot)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await store.searchKnowledge(.init(query: "手書き")).hits.isEmpty)
    }

    @Test func assetMutationAndAbsentReceiptsFailClosedAcrossReopen() async throws {
        let (store, directory, cache) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await store.create("Ink.studycanvas", kind: .notebook)
        var content = initial.content; content.pages[0].drawingFile = "assets/ink.drawing"
        _ = try await store.save("Ink.studycanvas", content: content, expectedRevision: initial.revision,
                                 assets: ["assets/ink.drawing": Data([1, 2, 3])])
        let snapshot = try await store.knowledgeSnapshot("Ink.studycanvas", pageID: content.pages[0].id, includeAssets: true)
        try await store.commitRecognition([hit(snapshot)], matching: snapshot)
        let found = try await store.searchKnowledge(.init(query: "手書き"))
        let id = try #require(found.hits.first?.id)
        try Data([4, 5, 6]).write(to: directory.appendingPathComponent("Vault/Ink.studycanvas/assets/ink.drawing"))
        #expect(try await store.readKnowledgeFragment(id) == nil)
        let reopened = VaultStore(root: directory.appendingPathComponent("Vault"), indexDirectory: cache)
        #expect(try await reopened.searchKnowledge(.init(query: "手書き")).hits.isEmpty)
        let current = try await reopened.knowledgeSnapshot("Ink.studycanvas", pageID: content.pages[0].id, includeAssets: true)
        try await reopened.commitRecognition([hit(current)], matching: current)
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: namespace.appendingPathComponent("receipts.json"))
        let noReceipts = VaultStore(root: directory.appendingPathComponent("Vault"), indexDirectory: cache)
        #expect(try await noReceipts.searchKnowledge(.init(query: "手書き")).hits.isEmpty)
    }

    @Test func cropReplacementPreservesOtherRegionsAndNeverClaimsDocumentComplete() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try await store.create("Canvas.studycanvas", kind: .infinity)
        let pageID = initial.content.pages[0].id
        let left = try await store.knowledgeSnapshot("Canvas.studycanvas", pageID: pageID, region: .init(x: 0, width: 100, height: 100), includeAssets: true)
        let right = try await store.knowledgeSnapshot("Canvas.studycanvas", pageID: pageID, region: .init(x: 200, width: 100, height: 100), includeAssets: true)
        try await store.commitRecognition([hit(left, text: "left", id: "left")], matching: left, state: .complete)
        try await store.commitRecognition([hit(right, text: "right", id: "right")], matching: right)
        try await store.commitRecognition([], matching: left, state: .empty)
        #expect(try await store.searchKnowledge(.init(query: "left")).hits.isEmpty)
        let remaining = try await store.searchKnowledge(.init(query: "right"))
        #expect(remaining.hits.count == 1)
        #expect(remaining.coverage.ocr["complete"] == nil)
    }

    @Test func brokenCacheDoesNotFailPersistedSaveOrLegacySearch() async throws {
        let (store, directory, cache) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await store.create("A.md", kind: .markdown, text: "first")
        _ = try await store.searchKnowledge(.init(query: "first"))
        let namespace = try #require(FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).first)
        try FileManager.default.removeItem(at: namespace.appendingPathComponent("receipts.json"))
        try FileManager.default.createDirectory(at: namespace.appendingPathComponent("receipts.json"), withIntermediateDirectories: false)
        let old = try await store.load("A.md")
        var edited = old.content; edited.markdown = "persisted despite cache failure"
        _ = try await store.save("A.md", content: edited, expectedRevision: old.revision)
        #expect(await store.knowledgeError != nil)
        #expect(try await store.load("A.md").content.markdown == edited.markdown)
        #expect(try await store.search("despite").map(\.path) == ["A.md"])
    }

    @Test func rawDocumentKeepsExactRevisionAndMissingDrawingReferences() async throws {
        let (store, directory, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markdown = try await store.create("A.md", kind: .markdown, text: "saved")
        #expect(try await store.knowledgeDocument("A.md").revision == markdown.revision)
        let initial = try await store.create("Ink.studycanvas", kind: .notebook)
        var content = initial.content; content.pages[0].drawingFile = "assets/missing.drawing"
        let url = directory.appendingPathComponent("Vault/Ink.studycanvas/manifest.json")
        try JSONEncoder().encode(content).write(to: url, options: .atomic)
        let raw = try await store.knowledgeDocument("Ink.studycanvas")
        #expect(raw.content.pages[0].drawingFile == "assets/missing.drawing")
        #expect(!raw.needsRepair)
        #expect(raw.revision == (try await store.load("Ink.studycanvas")).revision)
        #expect(try JSONDecoder().decode(DocumentContent.self, from: Data(contentsOf: url)).pages[0].drawingFile == "assets/missing.drawing")
    }
}
