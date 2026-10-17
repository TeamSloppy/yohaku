import Foundation
import PencilKit
import StudyCanvas
import StudyCore
import Testing
import UIKit
@testable import StudyIntelligence
@testable import Yohaku

struct CanvasStudyTests {
    private let area = Rect(x: 0, y: 0, width: 240, height: 200)
    @MainActor private func workspace() async throws -> (WorkspaceModel, DocumentSession) {
        let workspace = WorkspaceModel()
        var config = workspace.agent.configuration; config.provider = .network; config.remoteID = "fixture"; config.supportsImages = true
        workspace.agent.configuration = config
        try await workspace.openVault(URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), remember: false)
        _ = try await workspace.store!.create("note.studycanvas", kind: .notebook)
        await workspace.open("note.studycanvas")
        let session = workspace.sessions["note.studycanvas"]!
        session.edit { $0.pages[0].objects = [.init(kind: .text, frame: Rect(x: 10, y: 10, width: 200, height: 100), content: "猫はかわいい。"),
            .init(kind: .text, frame: Rect(x: 220, y: 0, width: 200, height: 100), content: "outside crop")] }
        return (workspace, session)
    }
    @MainActor private func finish(_ workspace: WorkspaceModel) async {
        while workspace.markdownStudyRunning { await Task.yield() }
    }
    private var card: SourceGeneratedFlashcard {
        .init(japanese: "猫", reading: "ねこ", translation: "кошка", example: "猫がいます。", note: "Существительное", sourceID: "excerpt", quote: "猫はかわいい。")
    }
    @Test func finiteScopeAndInfinityRules() throws {
        var content = DocumentContent(kind: .infinity); let id = content.pages[0].id
        #expect(throws: Error.self) { try StudySourceSnapshot.canvasRegion(content, pageID: id, region: nil) }
        for region in [Rect(x: .nan), Rect(y: .infinity), Rect(x: 1e100), Rect(width: 0), Rect(width: 8193), Rect(width: 8192, height: 1)] {
            #expect(throws: Error.self) { try StudySourceSnapshot.canvasRegion(content, pageID: id, region: region) }
        }
        let negative = Rect(x: -500, y: 0, width: 100, height: 100)
        #expect(try StudySourceSnapshot.canvasRegion(content, pageID: id, region: negative) == negative)
        content.pages[0].height = .infinity
        #expect(throws: Error.self) { try StudySourceSnapshot.canvasRegion(content, pageID: id, region: area) }
    }
    @Test @MainActor func savedInkRenderAndContainedObjects() async throws {
        let (workspace, session) = try await workspace(); let id = session.content.pages[0].id
        let points = [CGPoint(x: 30, y: 150), CGPoint(x: 190, y: 150)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 10, height: 10), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let name = session.addAsset(drawing.dataRepresentation(), extension: "drawing")
        session.edit { $0.pages[0].drawingFile = name }
        let source = try await workspace.prepareCanvasStudy(session, pageID: id, region: area)
        #expect(!session.isDirty); #expect(source.originalText == "猫はかわいい。")
        #expect(source.contentRevision == session.content.contentRevision); #expect(source.pageID == id); #expect(source.region == area)
        let loaded = try await session.store.load(session.path)
        let frozen = DocumentSession(path: session.path, loaded: loaded, store: session.store)
        let expected = try await CanvasRenderer.image(session: frozen, pageID: id, region: area.cgRect)
        #expect(source.image == expected.pngData())
        let savedInk = try PKDrawing(data: await frozen.asset(name)); #expect(savedInk.strokes.count == 1)
        let png = try #require(source.image)
        let pixels = try #require(UIImage(data: png)?.cgImage)
        #expect(pixels.width == 480); #expect(pixels.height == 400)
    }
    @Test @MainActor func strictRecognitionAndCapability() throws {
        #expect(try CanvasTranscription.parse(#"{"text":"猫","unclear":true}"#).unclear)
        for json in [#"{"text":"","unclear":false}"#, #"{"text":"猫","unclear":0}"#, #"{"text":"猫","unclear":false,"extra":1}"#, "not json"] {
            #expect(throws: Error.self) { try CanvasTranscription.parse(json) }
        }
        var config = ModelConfiguration(); config.localID = "unknown/model"
        #expect(throws: Error.self) { try AgentSession.validateVision(config) }
        config.provider = .network; config.supportsImages = false
        #expect(throws: Error.self) { try AgentSession.validateVision(config) }
    }
    @Test @MainActor func confirmationAndSavedProvenance() async throws {
        let (workspace, session) = try await workspace()
        let source = try await workspace.prepareCanvasStudy(session, pageID: session.content.pages[0].id, region: area)
        workspace.generateMarkdownStudy(source) { _ in [card] }; #expect(!workspace.markdownStudyRunning)
        workspace.recognizeCanvasStudy(source) { _ in try CanvasTranscription.parse(#"{"text":"犬","unclear":true}"#) }
        await finish(workspace); #expect(workspace.canvasStudyRecognition?.text == "犬")
        #expect(throws: Error.self) { try source.confirmingTranscription(" ") }
        let confirmed = try source.confirmingTranscription("猫はかわいい。")
        workspace.generateMarkdownStudy(confirmed) { _ in [card] }; await finish(workspace)
        #expect(await workspace.acceptMarkdownStudy(confirmed, selected: [0]))
        let saved = try #require(workspace.flashcards.cards.first)
        #expect(saved.sourcePageID == source.pageID); #expect(saved.sourceRegion == area)
        #expect(saved.sourceTextOrigin == .confirmedTranscription); #expect(saved.sourceExcerpt == card.quote)
        workspace.cancelMarkdownStudy(); #expect(workspace.markdownStudyCards.isEmpty)
    }
    @Test @MainActor func confirmedTranscriptionEditStaysStaleAfterRestart() async throws {
        let (workspace, session) = try await workspace(); let root = workspace.root!
        let source = try await workspace.prepareCanvasStudy(session, pageID: session.content.pages[0].id, region: area).confirmingTranscription("猫はかわいい。")
        workspace.generateMarkdownStudy(source) { _ in [card] }; await finish(workspace)
        let id = try #require(workspace.materials.records.first?.id)
        workspace.cancelMarkdownStudy()
        let context = try await workspace.prepareCanvasStudy(session, pageID: session.content.pages[0].id, region: area)
        workspace.invalidateStudyTranscription(context, text: "変更")
        while workspace.materials.records.first?.sourceSuperseded != true { await Task.yield() }
        let reopened = WorkspaceModel(); try await reopened.openVault(root, remember: false)
        #expect(reopened.materials.records.first?.freshness == .stale)
        #expect(!(await reopened.acceptStudyMaterials([id])))
        try? FileManager.default.removeItem(at: root)
    }
    @Test @MainActor func removedSourcePageBlocksSavedProposal() async throws {
        let (workspace, session) = try await workspace(); let root = workspace.root!
        let source = try await workspace.prepareCanvasStudy(session, pageID: session.content.pages[0].id, region: area).confirmingTranscription("猫はかわいい。")
        workspace.generateMarkdownStudy(source) { _ in [card] }; await finish(workspace)
        let id = try #require(workspace.materials.records.first?.id)
        session.edit { $0.pages.removeAll() }; await session.save(); await workspace.refreshStudyMaterials()
        #expect(workspace.materials.records.first?.freshness == .stale)
        #expect(!(await workspace.acceptStudyMaterials([id])))
        try? FileManager.default.removeItem(at: root)
    }
    @Test(arguments: 0..<7) @MainActor func lateRecognitionCannotOutliveSource(variant: Int) async throws {
        let (workspace, session) = try await workspace(); let root = workspace.root!
        let source = try await workspace.prepareCanvasStudy(session, pageID: session.content.pages[0].id, region: area)
        let gate = CanvasRecognitionGate()
        workspace.recognizeCanvasStudy(source) { _ in await gate.wait() }
        while gate.continuation == nil { await Task.yield() }
        switch variant {
        case 0: session.edit { $0.pages[0].title += "changed" }
        case 1:
            let loaded = try await session.store.load(session.path); var content = loaded.content; content.pages[0].objects = []
            _ = try await session.store.save(session.path, content: content, expectedRevision: loaded.revision)
        case 2: try FileManager.default.removeItem(at: root.appendingPathComponent(session.path))
        case 3: try FileManager.default.moveItem(at: root.appendingPathComponent(session.path), to: root.appendingPathComponent("moved.studycanvas"))
        case 4: workspace.cancelMarkdownStudy()
        case 5: workspace.agent.configuration.remoteID = "changed"
        default:
            try await workspace.openVault(URL.temporaryDirectory.appendingPathComponent(UUID().uuidString), remember: false)
            try await workspace.openVault(root, remember: false); await workspace.open(session.path)
        }
        gate.continuation?.resume(returning: try CanvasTranscription.parse(#"{"text":"猫","unclear":false}"#))
        await finish(workspace); #expect(workspace.canvasStudyRecognition == nil); #expect(workspace.markdownStudyCards.isEmpty)
    }
    @Test @MainActor func unavailableCapabilityAndAssetsNeverStartRecognition() async throws {
        let (workspace, session) = try await workspace(); let id = session.content.pages[0].id
        var config = workspace.agent.configuration; config.supportsImages = false; workspace.agent.configuration = config
        let source = try await workspace.prepareCanvasStudy(session, pageID: id, region: area)
        var requested = false
        workspace.recognizeCanvasStudy(source) { _ in requested = true; return try CanvasTranscription.parse(#"{"text":"猫","unclear":false}"#) }
        await finish(workspace); #expect(!requested); #expect(workspace.markdownStudyError != nil)
        let name = session.addAsset(Data("not an image".utf8), extension: "png")
        session.edit { $0.pages[0].objects.append(.init(kind: .image, frame: area, content: name)) }
        await #expect(throws: Error.self) { try await workspace.prepareCanvasStudy(session, pageID: id, region: area) }
        session.conflictPath = "conflict.studycanvas"
        await #expect(throws: Error.self) { try await workspace.prepareCanvasStudy(session, pageID: id, region: area) }
    }
}
@MainActor private final class CanvasRecognitionGate {
    var continuation: CheckedContinuation<CanvasTranscription, Never>?
    func wait() async -> CanvasTranscription { await withCheckedContinuation { continuation = $0 } }
}
