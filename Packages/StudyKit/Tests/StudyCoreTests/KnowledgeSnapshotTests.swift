import Foundation
import Testing
@testable import StudyCore

struct KnowledgeSnapshotTests {
    private func fixture(kind: DocumentKind = .notebook) async throws -> (VaultStore, URL, String, DocumentContent) {
        let directory = URL.temporaryDirectory.appendingPathComponent("KnowledgeSnapshot-\(UUID())")
        let store = VaultStore(root: directory.appendingPathComponent("Vault"))
        try await store.prepare()
        let path = "Folder/Notes.\(kind.fileExtension)"
        let initial = try await store.create(path, kind: kind)
        return (store, directory, path, initial.content)
    }

    private func write(_ content: DocumentContent, store: VaultStore, path: String) async throws {
        let url = try await store.fileURL(path).appendingPathComponent("manifest.json")
        try JSONEncoder().encode(content).write(to: url, options: .atomic)
    }

    @Test func originalMissingReferencesAreNotRepairedOrHydrated() async throws {
        let (store, directory, path, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var content = initial
        content.pages[0].drawingFile = "assets/missing.drawing"
        content.pages[0].shards = [.init(file: "assets/missing-shard.drawing", bounds: .init())]
        try await write(content, store: store, path: path)
        let manifest = try await store.fileURL(path).appendingPathComponent("manifest.json")
        let originalBytes = try Data(contentsOf: manifest)
        let raw = try await store.knowledgeSnapshot(path)
        #expect(raw.content == content)
        #expect(raw.assets.isEmpty && raw.hasCompleteAssets)
        let ink = try await store.knowledgeSnapshot(path, pageID: content.pages[0].id, includeAssets: true)
        #expect(ink.content.pages[0].drawingFile == "assets/missing.drawing")
        #expect(ink.missingAssets == ["assets/missing-shard.drawing", "assets/missing.drawing"])
        #expect(!ink.hasCompleteAssets && ink.unavailableAssets.isEmpty)
        #expect(try Data(contentsOf: manifest) == originalBytes)
        #expect(try await store.validateKnowledgeSnapshot(ink))
    }

    @Test func regionCapturesLegacyCrossingShardsAndIntersectingImages() async throws {
        let (store, directory, path, initial) = try await fixture(kind: .infinity)
        defer { try? FileManager.default.removeItem(at: directory) }
        var content = initial
        let crop = Rect(x: 0, y: 0, width: 100, height: 100)
        content.pages[0].drawingFile = "assets/legacy.drawing"
        content.pages[0].shards = [
            .init(file: "assets/crossing.drawing", bounds: .init(x: -1000, y: 50, width: 1050, height: 20)),
            .init(file: "assets/far.drawing", bounds: .init(x: 5000, y: 0, width: 50, height: 50))
        ]
        content.pages[0].objects = [
            .init(kind: .image, frame: crop, content: "assets/near.png"),
            .init(kind: .image, frame: .init(x: 5000, y: 0), content: "assets/far.png")
        ]
        let loaded = try await store.load(path)
        try await store.save(path, content: content, expectedRevision: loaded.revision, assets: [
            "assets/legacy.drawing": Data([1]), "assets/crossing.drawing": Data([2]), "assets/near.png": Data([3])
        ])
        let snapshot = try await store.knowledgeSnapshot(path, pageID: content.pages[0].id, region: crop, includeAssets: true)
        #expect(Set(snapshot.assets.keys) == ["assets/legacy.drawing", "assets/crossing.drawing", "assets/near.png"])
        #expect(snapshot.hasCompleteAssets)
        #expect(snapshot.sourceFingerprint == content.contentRevision)
        let text = try await store.knowledgeSnapshot(path)
        #expect(text.sourceFingerprint == snapshot.sourceFingerprint)
        #expect(text.fingerprint != snapshot.fingerprint)
        let package = try await store.fileURL(path)
        try Data([9]).write(to: package.appendingPathComponent("assets/near.png"))
        #expect(try await store.validateKnowledgeSnapshot(snapshot) == false)
        #expect(try await store.validateKnowledgeSnapshot(text))
    }

    @Test func invalidSelectionsAndEscapingReferencesAreRejected() async throws {
        let (store, directory, path, initial) = try await fixture(kind: .infinity)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pageID = initial.pages[0].id
        await #expect(throws: KnowledgeSnapshotError.explicitRegionRequired) {
            try await store.knowledgeSnapshot(path, pageID: pageID, includeAssets: true)
        }
        for region in [Rect(width: -1), Rect(x: .infinity), Rect(width: 8193), Rect(width: 8192, height: 8192)] {
            await #expect(throws: KnowledgeSnapshotError.invalidRegion) {
                try await store.knowledgeSnapshot(path, pageID: pageID, region: region, includeAssets: true)
            }
        }
        await #expect(throws: StudyError.self) { try await store.knowledgeSnapshot(path, pageID: UUID()) }
        await #expect(throws: StudyError.self) { try await store.knowledgeSnapshot("../Outside.md") }
        var content = initial
        content.pages[0].drawingFile = "../outside.drawing"
        try await write(content, store: store, path: path)
        await #expect(throws: StudyError.self) {
            try await store.knowledgeSnapshot(path, pageID: pageID, region: .init(), includeAssets: true)
        }
    }

    @Test func byteAndAssetLimitsApplyBeforeLoadingPayloads() async throws {
        let (store, directory, path, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var content = initial
        content.pages[0].drawingFile = "assets/large.drawing"
        let package = try await store.fileURL(path), assets = package.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let large = assets.appendingPathComponent("large.drawing")
        _ = FileManager.default.createFile(atPath: large.path, contents: Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(KnowledgeSnapshotLimits.bytes)); try handle.close()
        try await write(content, store: store, path: path)
        await #expect(throws: KnowledgeSnapshotError.byteLimitExceeded) {
            try await store.knowledgeSnapshot(path, pageID: content.pages[0].id, includeAssets: true)
        }
        content.pages[0].drawingFile = nil
        content.pages[0].shards = (0...KnowledgeSnapshotLimits.assets).map {
            .init(file: "assets/\($0).drawing", bounds: .init())
        }
        try await write(content, store: store, path: path)
        await #expect(throws: KnowledgeSnapshotError.assetLimitExceeded) {
            try await store.knowledgeSnapshot(path, pageID: content.pages[0].id, includeAssets: true)
        }
    }

    @Test func chatOnlySavesPreserveFingerprintsButSourceEditsAndDeletionRejectCommit() async throws {
        let (store, directory, path, initial) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try await store.knowledgeSnapshot(path)
        var content = initial
        content.messages = [.init(role: .assistant, text: "Derived answer")]
        content.appliedProposals = [UUID()]
        try await write(content, store: store, path: path)
        let chat = try await store.knowledgeSnapshot(path)
        #expect(chat.fingerprint == snapshot.fingerprint && chat.sourceFingerprint == snapshot.sourceFingerprint)
        #expect(try await store.validateKnowledgeSnapshot(snapshot))
        content.pages[0].title = "Changed source"
        try await write(content, store: store, path: path)
        #expect(try await store.validateKnowledgeSnapshot(snapshot) == false)
        let current = try await store.knowledgeSnapshot(path)
        try FileManager.default.removeItem(at: await store.fileURL(path))
        #expect(try await store.validateKnowledgeSnapshot(current) == false)
    }

    @Test func duplicateDocumentIDsUseIndependentPathsAndIdenticalReplacementIsRejected() async throws {
        let (store, directory, path, _) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path), copyPath = "Folder/Copy.studycanvas"
        let copyURL = try await store.fileURL(copyPath)
        try FileManager.default.copyItem(at: package, to: copyURL)
        let original = try await store.knowledgeSnapshot(path), copy = try await store.knowledgeSnapshot(copyPath)
        #expect(original.content.id == copy.content.id)
        #expect(original.sourceFingerprint == copy.sourceFingerprint && original.fingerprint != copy.fingerprint)
        let moved = directory.appendingPathComponent("Replaced.studycanvas")
        try FileManager.default.moveItem(at: package, to: moved)
        try FileManager.default.copyItem(at: moved, to: package)
        #expect(try await store.validateKnowledgeSnapshot(original) == false)
        #expect(try await store.validateKnowledgeSnapshot(copy))
    }

    @Test func markdownWithoutMetadataUsesSavedTextAndStableRevision() async throws {
        let (store, directory, path, _) = try await fixture(kind: .markdown)
        defer { try? FileManager.default.removeItem(at: directory) }
        let externalPath = "External.md", url = try await store.fileURL(externalPath)
        try Data("Saved external text".utf8).write(to: url)
        let snapshot = try await store.knowledgeSnapshot(externalPath)
        #expect(snapshot.content.markdown == "Saved external text" && snapshot.assets.isEmpty)
        #expect(try await store.knowledgeSnapshot(externalPath).fingerprint == snapshot.fingerprint)
        #expect(try await store.validateKnowledgeSnapshot(snapshot))
        #expect(path != externalPath)
    }
}
