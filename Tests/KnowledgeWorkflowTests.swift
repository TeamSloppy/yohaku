import Foundation
import StudyCore
import Testing
@testable import Yohaku

@MainActor @Suite(.serialized) struct KnowledgeWorkflowTests {
    private func fixture() async throws -> (WorkspaceModel, DocumentSession) {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(root: root, indexDirectory: root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString))
        try await store.prepare()
        let loaded = try await store.create("Notebook.studycanvas", kind: .notebook)
        let session = DocumentSession(path: "Notebook.studycanvas", loaded: loaded, store: store)
        let workspace = WorkspaceModel(); workspace.store = store
        workspace.sessions[session.path] = session
        workspace.tabs = [.init(path: session.path, pageID: session.content.pages[0].id)]
        workspace.activePath = session.path
        return (workspace, session)
    }
    private func finishSearch(_ workspace: WorkspaceModel) async throws {
        let deadline = Date().addingTimeInterval(4)
        while workspace.knowledgeSearching && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!workspace.knowledgeSearching)
    }
    @Test func rawQueryOpensItsExactPageAndRegion() async throws {
        let (workspace, session) = try await fixture()
        let page = CanvasPage()
        let region = Rect(x: 80, y: 170, width: 200, height: 60)
        session.edit {
            $0.pages.append(page)
            $0.pages[1].objects.append(.init(kind: .text, frame: region, content: "日本語 lexical-marker"))
        }
        await session.save()
        workspace.query = "lexical-marker"; workspace.search(); try await finishSearch(workspace)
        let hit = try #require(workspace.knowledgeResults.first { $0.provenance == .raw })
        #expect(hit.pageID == page.id && hit.region == region)
        await workspace.open(hit.sourceContext)
        #expect(workspace.tabs[0].pageID == page.id)
        #expect(workspace.sourceNavigation?.region == region)
    }
    @Test func queryGenerationAndVaultSwitchDiscardOldResults() async throws {
        let (workspace, session) = try await fixture()
        workspace.query = "Notebook"; workspace.search()
        workspace.query = "no-match"; workspace.search(); try await finishSearch(workspace)
        #expect(workspace.knowledgeResults.isEmpty)
        workspace.query = "Notebook"; workspace.search()
        try await workspace.openVault(URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), remember: false, iCloud: false)
        try await finishSearch(workspace)
        #expect(workspace.store !== session.store)
        #expect(workspace.knowledgeResults.isEmpty && workspace.searchResults.isEmpty)
    }
    @Test func recognitionIdentityRejectsUnsavedEditsConflictsAndOtherVaults() async throws {
        let (workspace, session) = try await fixture()
        let request = HandwritingRecognitionRequest(source: .init(path: session.path, pageID: session.content.pages[0].id),
            revision: session.content.contentRevision, store: session.store)
        #expect(request.isCurrent(session: session, workspace: workspace))
        session.conflictPath = "Conflict.studycanvas"
        #expect(!request.isCurrent(session: session, workspace: workspace))
        session.conflictPath = nil
        session.edit { $0.pages[0].title = "Changed" }
        #expect(!request.isCurrent(session: session, workspace: workspace))
        await session.save()
        #expect(!request.isCurrent(session: session, workspace: workspace))
        workspace.store = VaultStore(root: URL.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(!request.isCurrent(session: session, workspace: workspace))
    }
}
