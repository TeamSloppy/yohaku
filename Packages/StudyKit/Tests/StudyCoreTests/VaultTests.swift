import Foundation
import Testing
@testable import StudyCore

struct VaultTests {
    func vault() async throws -> VaultStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StudyTests-\(UUID())")
        let store = VaultStore(root: root); try await store.prepare(); return store
    }
    @Test func roundTripAndStaleRevision() async throws {
        let store = try await vault()
        let first = try await store.create("日本語/練習.studycanvas", kind: .notebook)
        var changed = first.content; changed.pages[0].paper.pattern = .japanese
        changed.pages[0].drawingFile = "assets/test.drawing"
        let saved = try await store.save("日本語/練習.studycanvas", content: changed, expectedRevision: first.revision, assets: ["assets/test.drawing": Data([1, 2, 3])])
        #expect(saved.content == changed)
        #expect(try await store.readAsset("日本語/練習.studycanvas", name: "assets/test.drawing") == Data([1, 2, 3]))
        await #expect(throws: StudyError.self) { try await store.save("日本語/練習.studycanvas", content: first.content, expectedRevision: first.revision) }
    }
    @Test func proposalsAreRevisionCheckedAndIdempotent() async throws {
        let store = try await vault()
        let first = try await store.create("Note.md", kind: .markdown, text: "before")
        let proposal = ChangeProposal(action: .replaceMarkdown, path: "Note.md", baseRevision: first.content.contentRevision, text: "after")
        let applied = try await store.apply(proposal)
        #expect(try await store.apply(proposal).revision == applied.revision)
        let stale = ChangeProposal(action: .replaceMarkdown, path: "Note.md", baseRevision: first.content.contentRevision, text: "lost edit")
        await #expect(throws: StudyError.self) { try await store.apply(stale) }
        #expect(try await store.load("Note.md").content.markdown == "after")
    }
    @Test func moveRewritesIncomingAndOutgoingLinks() async throws {
        let store = try await vault()
        try await store.create("A/One.md", kind: .markdown, text: "[other](../B/Two.md#page)")
        try await store.create("B/Two.md", kind: .markdown, text: "[one](../A/One.md)")
        try await store.move("A", to: "C/Nested")
        #expect(try await store.load("C/Nested/One.md").content.markdown == "[other](../../B/Two.md#page)")
        #expect(try await store.load("B/Two.md").content.markdown == "[one](../C/Nested/One.md)")
        #expect(try await store.backlinks(to: "B/Two.md").map(\.path) == ["C/Nested/One.md"])
    }
    @Test func rejectsTraversalAndSymlinkEscape() async throws {
        let store = try await vault()
        await #expect(throws: StudyError.self) { try await store.create("../escape.md", kind: .markdown) }
        let root = await store.root
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: FileManager.default.temporaryDirectory)
        await #expect(throws: StudyError.self) { try await store.create("escape/bad.md", kind: .markdown) }
    }
    @Test func externalEditIsPreservedAndConflictCopyContainsAssets() async throws {
        let store = try await vault()
        let loaded = try await store.create("Note.md", kind: .markdown, text: "original")
        let url = try await store.fileURL("Note.md")
        try Data("external 日本語".utf8).write(to: url)
        await #expect(throws: StudyError.self) { try await store.save("Note.md", content: loaded.content, expectedRevision: loaded.revision) }
        let copy = try await store.preserveConflict("Note.md", content: loaded.content, assets: [:])
        #expect(try await store.load(copy).content.markdown == "original")
        #expect(try await store.load("Note.md").content.markdown == "external 日本語")
    }
    @Test func repeatedConflictPreservationReusesOneCanonicalRecoveryCopy() async throws {
        let store = try await vault()
        let loaded = try await store.create("Практика — конфликт 1234ABCD.studycanvas", kind: .infinity)
        var local = loaded.content
        local.pages[0].objects.append(.init(kind: .text, content: "офлайн-конспект"))
        let first = try await store.preserveConflict("Практика — конфликт 1234ABCD.studycanvas", content: local, assets: [:])
        let second = try await store.preserveConflict("Практика — конфликт 1234ABCD.studycanvas", content: local, assets: [:])
        #expect(first == second)
        #expect(first.hasPrefix("Практика — восстановлено "))
        #expect(!first.contains("— конфликт 1234ABCD —"))
        #expect(try await store.load(first).content.pages[0].objects.first?.content == "офлайн-конспект")
    }
    @Test func deletionMarkerSuppressesLateCloudReturnAndExplicitCreateClearsIt() async throws {
        let store = try await vault()
        try await store.create("Возвращается.md", kind: .markdown, text: "old")
        try await store.trash("Возвращается.md")
        #expect(!((try await store.list()).contains { $0.path == "Возвращается.md" }))

        let url = try await store.fileURL("Возвращается.md")
        try Data("late iCloud copy".utf8).write(to: url)
        // Explicit recreation must first suppress a provider copy that arrived
        // after deletion, even when no list refresh happened in between.
        try await store.create("Возвращается.md", kind: .markdown, text: "new")
        #expect(try await store.load("Возвращается.md").content.markdown == "new")
    }
    @MainActor @Test func missingDrawingReferenceRecoversNonemptyOrphanAndPersistsRepair() async throws {
        let store = try await vault()
        let initial = try await store.create("Конспект.studycanvas", kind: .notebook)
        var broken = initial.content
        broken.pages[0].drawingFile = "assets/missing.drawing"
        _ = try await store.save(
            "Конспект.studycanvas",
            content: broken,
            expectedRevision: initial.revision,
            assets: ["assets/orphan.drawing": Data(repeating: 1, count: 128)]
        )

        let repaired = try await store.load("Конспект.studycanvas")
        #expect(repaired.needsRepair)
        #expect(repaired.content.pages[0].drawingFile == nil)
        #expect(repaired.content.pages.last?.drawingFile == "assets/orphan.drawing")

        let session = DocumentSession(path: "Конспект.studycanvas", loaded: repaired, store: store)
        #expect(session.isDirty)
        await session.save()
        let persisted = try await store.load("Конспект.studycanvas")
        #expect(!persisted.needsRepair)
        #expect(persisted.content.pages.last?.drawingFile == "assets/orphan.drawing")
    }
    @MainActor @Test func newerDrawingSaveDoesNotPrunePreviousImmutableSnapshot() async throws {
        let store = try await vault()
        let session = DocumentSession(
            path: "Offline.studycanvas",
            loaded: try await store.create("Offline.studycanvas", kind: .notebook),
            store: store
        )
        let first = session.addAsset(Data(repeating: 1, count: 128), extension: "drawing")
        session.edit { $0.pages[0].drawingFile = first }
        await session.save()
        let second = session.addAsset(Data(repeating: 2, count: 128), extension: "drawing")
        session.edit { $0.pages[0].drawingFile = second }
        await session.save()

        #expect(try await store.readAsset("Offline.studycanvas", name: first) == Data(repeating: 1, count: 128))
        #expect(try await store.readAsset("Offline.studycanvas", name: second) == Data(repeating: 2, count: 128))
    }
    @Test func linkResolutionDoesNotEscapeVault() {
        #expect(NoteLinks.resolve("../../outside.md", source: "A/B.md") == nil)
        #expect(NoteLinks.resolve("https://example.com", source: "A.md") == nil)
        #expect(NoteLinks.resolve("../文法.md#page=one", source: "日本語/練習.md")?.path == "文法.md")
    }
    @Test func markdownPresentationDoesNotLeakIntoSource() {
        let source = "![画像](image.png)\n日本語 🇯🇵"
        let display = "\u{FFFC}[画像](image.png)\n日本語 🇯🇵"
        #expect(SourceProjection.applyingEdit(source: source, oldDisplay: display, newDisplay: display + "です") == source + "です")
        #expect(SourceProjection.applyingEdit(source: source, oldDisplay: display, newDisplay: display.replacingOccurrences(of: "日本語", with: "にほんご")) == source.replacingOccurrences(of: "日本語", with: "にほんご"))
    }
    @Test func stalePresentationNeverRestoresOldSource() {
        #expect(SourceProjection.applyingEdit(source: "old", oldDisplay: "new text", newDisplay: "new text!") == "new text!")
    }
    @Test func streamingChatDoesNotInvalidateDocumentProposal() async throws {
        let store = try await vault()
        let loaded = try await store.create("Note.md", kind: .markdown, text: "original")
        let proposal = ChangeProposal(action: .replaceMarkdown, path: "Note.md", baseRevision: loaded.content.contentRevision, text: "accepted")
        var chatting = loaded.content; chatting.messages.append(.init(role: .assistant, text: "Предлагаю изменить текст"))
        try await store.save("Note.md", content: chatting, expectedRevision: loaded.revision)
        #expect(try await store.apply(proposal).content.markdown == "accepted")
    }
    @Test func externalMarkdownHasStableIdentityAndMovePreservesLinks() async throws {
        let store = try await vault(), root = await store.root
        try Data("# 日本語\n".utf8).write(to: root.appendingPathComponent("External.md"))
        let first = try await store.load("External.md"), second = try await store.load("External.md")
        #expect(first.content.contentRevision == second.content.contentRevision)
        try await store.create("Link.md", kind: .markdown, text: "[note](External.md)\n`[code](External.md)`")
        try FileManager.default.moveItem(at: root.appendingPathComponent("External.md"), to: root.appendingPathComponent("Moved.md"))
        try await store.reconcileExternalMove("External.md", to: "Moved.md")
        #expect(try await store.load("Link.md").content.markdown == "[note](Moved.md)\n`[code](External.md)`")
    }
    @MainActor @Test func groupedUndoKeepsMessagesAndRestoresUserContent() async throws {
        let store = try await vault()
        let session = DocumentSession(path: "Note.md", loaded: try await store.create("Note.md", kind: .markdown, text: "original"), store: store)
        session.beginEditingGroup()
        session.edit { $0.markdown = "step one" }
        session.edit { $0.markdown = "step two" }
        session.endEditingGroup()
        session.edit { $0.messages.append(.init(role: .assistant, text: "answer")) }
        session.undo()
        #expect(session.content.markdown == "original")
        #expect(session.content.messages.last?.text == "answer")
        session.redo()
        #expect(session.content.markdown == "step two")
        await session.save()
    }
}
