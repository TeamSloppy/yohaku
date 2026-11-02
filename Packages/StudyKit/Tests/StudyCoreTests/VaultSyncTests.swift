import Foundation
import Darwin
import Synchronization
import Testing
@testable import StudyCore

private final class CloudFiles: VaultCloudFileAccess, Sendable {
    let statuses: [String: VaultFileSyncStatus]
    let rejected: Set<String>
    let requests = Mutex<[String]>([])
    init(_ statuses: [String: VaultFileSyncStatus], rejected: Set<String> = []) {
        self.statuses = statuses; self.rejected = rejected
    }
    func status(at url: URL) throws -> VaultFileSyncStatus { statuses[url.lastPathComponent] ?? .init(.local) }
    func requestDownload(at url: URL) throws {
        requests.withLock { $0.append(url.lastPathComponent) }
        if rejected.contains(url.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
    }
}

struct VaultSyncTests {
    @Test func partiallyDownloadedPackageIncludesEveryAssetWithoutReadingManifest() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = CloudFiles(["Notes.studycanvas": .init(.synced), "manifest.json": .init(.synced),
                                "ink.drawing": .init(.cloudOnly, isAvailableLocally: false)])
        let store = VaultStore(root: root, cloudFiles: cloud)
        try await store.prepare()
        let package = root.appendingPathComponent("Notes.studycanvas")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        // A FIFO would hang if status inspection tried to read package contents.
        #expect(mkfifo(package.appendingPathComponent("manifest.json").path, 0o600) == 0)
        try Data().write(to: package.appendingPathComponent("assets/ink.drawing"))
        let status = try await store.fileSyncStatus("Notes.studycanvas")
        #expect(status.state == .cloudOnly)
        #expect(!status.isAvailableLocally)
        #expect(try await !store.isAvailableLocally("Notes.studycanvas"))
        #expect(try await store.syncSnapshot().files["Notes.studycanvas"] == status)
        #expect(try await store.requestCloudDownloads("Notes.studycanvas").isEmpty)
        #expect(cloud.requests.withLock { $0 } == ["ink.drawing"])
    }

    @Test func fullSyncRequestsHiddenStudyFilesAndContinuesAfterAnIndividualFailure() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cloud = CloudFiles(["Note.md": .init(.cloudOnly, isAvailableLocally: false),
                               "flashcards.json": .init(.outdated), "deleted.md": .init(.cloudOnly, isAvailableLocally: false)],
                              rejected: ["Note.md"])
        let store = VaultStore(root: root, cloudFiles: cloud)
        try await store.prepare()
        for path in ["Note.md", ".workspace/flashcards.json", ".workspace/trash/deleted.md"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        let failures = try await store.requestCloudDownloads()
        #expect(failures.keys.sorted() == ["Note.md"])
        #expect(Set(cloud.requests.withLock { $0 }) == ["Note.md", "flashcards.json"])
        #expect(try await store.syncSnapshot().overall.state == .cloudOnly)
    }

    @Test func localSyncDoesNotRequestTransfersOrFollowSymlinks() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let cloud = CloudFiles(["Outside.md": .init(.cloudOnly, isAvailableLocally: false)])
        let store = VaultStore(root: root, cloudFiles: cloud)
        try await store.prepare()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("Outside.md"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: outside)
        try await store.create("Local.md", kind: .markdown, text: "offline")
        #expect(try await store.requestCloudDownloads().isEmpty)
        #expect(cloud.requests.withLock { $0.isEmpty })
        #expect(try await store.syncSnapshot().overall.state == .local)
    }

    @Test func aggregateNeverHidesMissingAssetsBehindATransferOrError() {
        let status = VaultFileSyncStatus.combined([.init(.cloudOnly, isAvailableLocally: false), .init(.uploading)])
        #expect(status.state == .uploading && !status.isAvailableLocally)
        let failed = VaultFileSyncStatus.combined([status, .init(.failed, detail: "No space")])
        #expect(failed.state == .failed && failed.detail == "No space" && !failed.isAvailableLocally)
        #expect(VaultFileSyncStatus.combined([.init(.synced), .init(.conflict)]).state == .conflict)
    }

    @Test func systemMetadataRecognizesLocalFilesAndRejectsMissingPaths() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(root: root)
        try await store.prepare()
        try await store.create("Note.md", kind: .markdown)
        #expect(try await store.fileSyncStatus("Note.md").state == .local)
        await #expect(throws: (any Error).self) { try await store.fileSyncStatus("Missing.md") }
        await #expect(throws: StudyError.self) { try await store.requestCloudDownloads("../outside") }
    }
}
