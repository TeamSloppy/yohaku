import Foundation
import Testing
import PencilKit
@testable import StudyCore

struct CanvasMaintenanceTests {
    private func drawingData() -> Data { PKDrawing().dataRepresentation() }
    private func fixture() async throws -> (VaultStore, URL, String) {
        let directory = URL.temporaryDirectory.appendingPathComponent("CanvasMaintenance-\(UUID())")
        let store = VaultStore(root: directory.appendingPathComponent("Vault")); try await store.prepare()
        let path = "Folder/Notes.studycanvas"
        let initial = try await store.create(path, kind: .notebook)
        var content = initial.content
        content.pages[0].drawingFile = "assets/current.drawing"
        content.pages[0].objects = [.init(kind: .image, content: "assets/image.png")]
        try await store.save(path, content: content, expectedRevision: initial.revision, assets: [
            "assets/current.drawing": drawingData(),
            "assets/obsolete.drawing": Data(repeating: 2, count: 8192),
            "assets/image.png": Data([3, 4, 5]),
            "assets/unknown.bin": Data([6, 7])
        ])
        return (store, directory, path)
    }

    @Test func analysisAndPreparationPreserveOriginalAndEveryRetainedByte() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path)
        let originalInk = try await store.readAsset(path, name: "assets/current.drawing")
        let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        let report = try await store.analyzeCanvasStorage(path)
        #expect(report.canCompact && report.reclaimableBytes == 8192 && report.obsoleteDrawingCount == 1, "\(report)")
        let prepared = try await store.prepareCanvasCompaction(report, backupDirectory: directory.appendingPathComponent("Backups"))
        #expect(try Data(contentsOf: package.appendingPathComponent("manifest.json")) == manifest)
        #expect(try await store.readAsset(path, name: "assets/current.drawing") == originalInk)
        #expect(try Data(contentsOf: prepared.compactURL.appendingPathComponent("manifest.json")) == manifest)
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("assets/obsolete.drawing").path))
        #expect(try Data(contentsOf: prepared.backupURL.appendingPathComponent("assets/obsolete.drawing")) == Data(repeating: 2, count: 8192))
        #expect(!FileManager.default.fileExists(atPath: prepared.compactURL.appendingPathComponent("assets/obsolete.drawing").path))
        for name in ["current.drawing", "image.png", "unknown.bin"] {
            #expect(try Data(contentsOf: prepared.compactURL.appendingPathComponent("assets/" + name)) == Data(contentsOf: package.appendingPathComponent("assets/" + name)))
        }
        try await store.applyCanvasCompaction(prepared)
        #expect(try Data(contentsOf: package.appendingPathComponent("manifest.json")) == manifest)
        #expect(try await store.analyzeCanvasStorage(path).reclaimableBytes == 0)
    }

    @MainActor @Test func compactionKeepsUndoAndRedoDrawingSnapshots() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = DocumentSession(path: path, loaded: try await store.load(path), store: store)
        let originalInk = try await store.readAsset(path, name: "assets/current.drawing")
        let newInk = drawingData()
        let newer = session.addAsset(newInk, extension: "drawing")
        session.edit { $0.pages[0].drawingFile = newer }; await session.save()
        let report = try await store.analyzeCanvasStorage(path, keeping: session.protectedAssetNames)
        let prepared = try await store.prepareCanvasCompaction(report, backupDirectory: directory.appendingPathComponent("Backups"))
        try await store.applyCanvasCompaction(prepared)
        session.undo(); await session.save()
        #expect(try await store.load(path).content.pages[0].drawingFile == "assets/current.drawing")
        #expect(try await store.readAsset(path, name: "assets/current.drawing") == originalInk)
        session.redo(); await session.save()
        #expect(try await store.readAsset(path, name: newer) == newInk)
    }

    @Test func missingReferencedDrawingBlocksPreparationWithoutRepairingManifest() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path)
        let manifest = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
        try FileManager.default.removeItem(at: package.appendingPathComponent("assets/current.drawing"))
        let report = try await store.analyzeCanvasStorage(path)
        #expect(!report.canCompact && report.missingAssets == ["assets/current.drawing"])
        await #expect(throws: StudyError.self) {
            try await store.prepareCanvasCompaction(report, backupDirectory: directory.appendingPathComponent("Backups"))
        }
        #expect(try Data(contentsOf: package.appendingPathComponent("manifest.json")) == manifest)
    }

    @Test func changedAssetInventoryRejectsAnOldPlanAndTamperedBackupRejectsApplication() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path)
        let report = try await store.analyzeCanvasStorage(path)
        try Data([9]).write(to: package.appendingPathComponent("assets/external.drawing"))
        await #expect(throws: StudyError.self) {
            try await store.prepareCanvasCompaction(report, backupDirectory: directory.appendingPathComponent("Backups"))
        }
        let fresh = try await store.analyzeCanvasStorage(path)
        let prepared = try await store.prepareCanvasCompaction(fresh, backupDirectory: directory.appendingPathComponent("Backups"))
        try Data([0]).write(to: prepared.backupURL.appendingPathComponent("assets/current.drawing"))
        await #expect(throws: StudyError.self) { try await store.applyCanvasCompaction(prepared) }
        #expect(FileManager.default.fileExists(atPath: package.appendingPathComponent("assets/obsolete.drawing").path))
    }

    @Test func unknownManifestReferencesAndRecoveryPagesAreRetained() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path), manifest = package.appendingPathComponent("manifest.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        json["futureAttachment"] = "assets/obsolete.drawing"
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        #expect(try await store.analyzeCanvasStorage(path).reclaimableBytes == 0)
        json.removeValue(forKey: "futureAttachment")
        var pages = try #require(json["pages"] as? [[String: Any]])
        var recovery = try #require(pages.first); recovery["id"] = UUID().uuidString
        recovery["title"] = "Восстановлено 1"; recovery["drawingFile"] = "assets/obsolete.drawing"
        pages.append(recovery); json["pages"] = pages
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        #expect(try await store.analyzeCanvasStorage(path).reclaimableBytes == 0)
    }

    @Test func backupInsideVaultAndEscapingSymlinksAreRejected() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await store.analyzeCanvasStorage(path), root = await store.root
        await #expect(throws: StudyError.self) { try await store.prepareCanvasCompaction(report, backupDirectory: root.appendingPathComponent("Backups")) }
        let package = try await store.fileURL(path)
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("assets/escape.drawing"), withDestinationURL: directory)
        await #expect(throws: StudyError.self) { try await store.analyzeCanvasStorage(path) }
    }
    @Test func unreadableCurrentInkAndChangedManifestBlockCleanup() async throws {
        let (store, directory, path) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = try await store.fileURL(path)
        let report = try await store.analyzeCanvasStorage(path)
        let prepared = try await store.prepareCanvasCompaction(report, backupDirectory: directory.appendingPathComponent("Backups"))
        let original = try await store.load(path)
        var changed = original.content; changed.pages[0].title = "New external edit"
        try await store.save(path, content: changed, expectedRevision: original.revision)
        await #expect(throws: StudyError.self) { try await store.applyCanvasCompaction(prepared) }
        #expect(try await store.load(path).content.pages[0].title == "New external edit")
        try Data([0]).write(to: package.appendingPathComponent("assets/current.drawing"))
        let invalid = try await store.analyzeCanvasStorage(path)
        #expect(!invalid.canCompact && invalid.blockers.contains { $0.contains("current.drawing") })
    }
}
