import Foundation
import AVFoundation
import StudyCore
import Testing
@testable import Yohaku

@MainActor struct DocumentRenameTests {
    @Test func bundledFeedbackSoundsArePlayableAndShort() throws {
        for effect in StudyFeedback.Effect.allCases {
            let url = try #require(Bundle.main.url(forResource: "study-" + effect.rawValue, withExtension: "wav"))
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0.2 && player.duration < 1.5)
            #expect(player.prepareToPlay())
        }
    }
    @Test func titlePreservesParentExtensionAndDottedFolderNames() {
        let canvas = DocumentRename(path: "日本語/Тетрадь/Словарь.studycanvas", isDirectory: false)
        #expect(canvas.name == "Словарь")
        #expect(canvas.destination(for: "  Мой словарь  ") == "日本語/Тетрадь/Мой словарь.studycanvas")
        #expect(DocumentRename(path: "Начало.md", isDirectory: false).destination(for: "Урок 1.2") == "Урок 1.2.md")
        let folder = DocumentRename(path: "日本語/Урок 1.2", isDirectory: true)
        #expect(folder.name == "Урок 1.2")
        #expect(folder.destination(for: "Урок 2.3") == "日本語/Урок 2.3")
        for invalid in ["", "  ", ".", "..", "../Другая папка", "Урок/1", "Урок:1"] {
            #expect(canvas.destination(for: invalid) == nil)
        }
    }

    @Test func successfulRenameMovesRealDocumentAndOpenTabWhileCollisionIsRecoverable() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceModel()
        try await workspace.openVault(root, remember: false)
        await workspace.createFolder("日本語")
        await workspace.create("Словарь", kind: .markdown, folder: "日本語")
        let old = "日本語/Словарь.md", renamed = "日本語/Новый словарь.md"
        #expect(await workspace.move(old, to: renamed))
        #expect(workspace.activePath == renamed)
        #expect(workspace.tabs.contains { $0.path == renamed })
        #expect(workspace.sessions[renamed]?.path == renamed)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(renamed).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(old).path))
        await workspace.create("Занято", kind: .markdown, folder: "日本語")
        #expect(!(await workspace.move(renamed, to: "日本語/Занято.md")))
        #expect(workspace.error != nil)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(renamed).path))
        #expect(await workspace.move(renamed, to: renamed))
        workspace.error = nil
        await workspace.create("Тетрадь", kind: .notebook, folder: "日本語")
        #expect(await workspace.move("日本語/Тетрадь.studycanvas", to: "日本語/Новая тетрадь.studycanvas"))
        #expect(workspace.activePath == "日本語/Новая тетрадь.studycanvas")
        #expect(workspace.sessions["日本語/Новая тетрадь.studycanvas"]?.content.kind == .notebook)
    }
}
