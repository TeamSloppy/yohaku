import AnyLanguageModel
import Foundation
import StudyCore
import StudyCanvas
import Testing
@testable import StudyIntelligence
#if canImport(UIKit)
import PencilKit
import UIKit
#endif

@MainActor struct KnowledgeAgentToolsTests {
    private func fixture() async throws -> (VaultStore, URL) {
        let root = URL.temporaryDirectory.appendingPathComponent("KnowledgeTools-\(UUID())")
        let store = VaultStore(root: root.appendingPathComponent("Vault"), indexDirectory: root.appendingPathComponent("Cache"))
        try await store.prepare(); return (store, root)
    }
    private func json(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    @Test func sharedSearchHasIdenticalPagesCoverageAndExactOCRCoordinates() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await store.create("Canvas.studycanvas", kind: .infinity)
        let crop = Rect(x: -4000, y: 1800, width: 500, height: 200)
        let snapshot = try await store.knowledgeSnapshot("Canvas.studycanvas", pageID: loaded.content.pages[0].id, region: crop, includeAssets: true)
        try await store.commitRecognition([.init(id: "ocr-line", path: "Canvas.studycanvas", pageID: snapshot.source.pageID,
                                                 region: crop, text: "日本語 shared", provenance: .ocr,
                                                 sourceFingerprint: snapshot.sourceFingerprint, language: "ja", confidence: 0.8,
                                                 runFingerprint: "fixture", engineFingerprint: "fixture")], matching: snapshot)
        _ = try await store.create("Raw.md", kind: .markdown, text: "日本語 shared")
        let access = KnowledgeToolAccess(store: store)
        let expected = try await store.searchKnowledge(.init(query: "日本語", limit: 1))
        let first = try json(await access.search(query: "日本語", limit: 1))
        let hits = try #require(first["hits"] as? [[String: Any]])
        #expect(hits.map { $0["fragmentID"] as? String } == expected.hits.map { Optional($0.id) })
        #expect(first["nextCursor"] as? String == expected.nextCursor)
        let coverage = try JSONDecoder().decode(KnowledgeSearchCoverage.self, from: JSONSerialization.data(withJSONObject: #require(first["coverage"])))
        #expect(coverage == expected.coverage)
        let all = try json(await access.search(query: "日本語", limit: 40))
        let ocr = try #require((all["hits"] as? [[String: Any]])?.first { $0["provenance"] as? String == "ocr" })
        #expect((ocr["region"] as? [String: Double])?["x"] == crop.x)
        #expect(ocr["pageID"] as? String == snapshot.source.pageID?.uuidString)
        let second = try json(await access.search(query: "日本語", limit: 1, cursor: #require(expected.nextCursor)))
        #expect((second["hits"] as? [[String: Any]])?.count == 1)
    }
    @Test func searchAndFragmentAreBoundedAndStaleReferencesFailClosed() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await store.create("Long.md", kind: .markdown, text: "needle " + String(repeating: "長", count: 20_000))
        let access = KnowledgeToolAccess(store: store)
        let search = try await access.search(query: "needle")
        #expect(search.count < KnowledgeToolAccess.maximumOutputCharacters)
        let hit = try #require((json(search)["hits"] as? [[String: Any]])?.first)
        #expect((hit["text"] as? String)?.count == 400)
        let ref = try #require(hit["source_ref"] as? String)
        let read = try json(await access.readFragment(ref))
        #expect((read["text"] as? String)?.count == 12_000)
        #expect(read["textTruncated"] as? Bool == true)
        let citations = await access.citations(in: "Answer [[\(ref)]] [[source_invented]]")
        #expect(citations.count == 1)
        let citation = try #require(citations.first)
        #expect(try await KnowledgeToolAccess.validate(citation, store: store).path == "Long.md")
        var edited = loaded.content; edited.markdown = "replaced"
        _ = try await store.save("Long.md", content: edited, expectedRevision: loaded.revision)
        await #expect(throws: StudyError.self) { _ = try await access.readFragment(ref) }
        await #expect(throws: StudyError.self) { _ = try await KnowledgeToolAccess.validate(citation, store: store) }
        await #expect(throws: StudyError.self) { _ = try await access.search(query: String(repeating: "a", count: 501)) }
    }
    @Test func searchDefaultAndMaximumLimitsKeepCursorAndExplicitTruncation() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<45 { _ = try await store.create("Note-\(i).md", kind: .markdown, text: "common") }
        let access = KnowledgeToolAccess(store: store)
        let first = try json(await access.search(query: "common"))
        #expect((first["hits"] as? [[String: Any]])?.count == 10)
        #expect(first["truncated"] as? Bool == true)
        #expect(first["nextCursor"] as? String != nil)
        let capped = try json(await access.search(query: "common", limit: 500))
        #expect((capped["hits"] as? [[String: Any]])?.count == 40)
    }
    @Test func registryRejectsOtherRunsAndOldChatsDecodeWithoutCitations() throws {
        var registry = KnowledgeCitationRegistry()
        let issued = registry.issue(source: .init(path: "A.md", text: "evidence", image: Data([1, 2])), fingerprint: "saved")
        let text = "Answer [[\(issued.id)]] [[source_fabricated]] [[\(issued.id)]]"
        let sources = registry.citations(in: text)
        #expect(sources.count == 1); #expect(sources[0].source.image == nil)
        #expect(KnowledgeCitationRegistry().citations(in: text).isEmpty)
        #expect(!KnowledgeCitationRegistry.displayText(text).contains("[[source_"))
        var message = ChatMessage(role: .assistant, text: text); message.citations = sources
        let encoded = try JSONEncoder().encode(message)
        #expect(try JSONDecoder().decode(ChatMessage.self, from: encoded) == message)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any]); legacy.removeValue(forKey: "citations")
        #expect(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: legacy)).citations == nil)
    }
    @Test func documentReferencesPersistButRejectAChangedDocument() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await store.create("Document.md", kind: .markdown, text: "saved text")
        let access = KnowledgeToolAccess(store: store)
        let result = try await access.readDocument("Document.md")
        #expect(result.revision == loaded.content.contentRevision)
        let ref = try #require(json(result.output)["source_ref"] as? String)
        let sources = await access.citations(in: "[[\(ref)]]")
        var message = ChatMessage(role: .assistant, text: "[[\(ref)]]"); message.citations = sources
        let saved = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        let citation = try #require(saved.citations?.first)
        #expect(try await KnowledgeToolAccess.validate(citation, store: store).path == "Document.md")
        var chatOnly = loaded.content; chatOnly.messages = [saved]
        _ = try await store.save("Document.md", content: chatOnly, expectedRevision: loaded.revision)
        let reloaded = try await store.knowledgeDocument("Document.md")
        let persisted = try #require(reloaded.content.messages.first?.citations?.first)
        #expect(try await KnowledgeToolAccess.validate(persisted, store: store).path == "Document.md")
        _ = try await store.apply(.init(action: .replaceMarkdown, path: "Document.md", baseRevision: result.revision, text: "new"))
        await #expect(throws: StudyError.self) { _ = try await KnowledgeToolAccess.validate(citation, store: store) }
    }
    @Test func nativeReadStillAllowsRevisionGuardedProposalsWithoutApplyingThem() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await store.create("A.md", kind: .markdown, text: "original")
        let document = DocumentSession(path: "A.md", loaded: loaded, store: store)
        var proposals: [ChangeProposal] = []
        let runtime = NotesToolRuntime(document: document, propose: { proposals.append($0) })
        let modelSession = LanguageModelSession(model: OpenAILanguageModel(apiKey: "test", model: "test"))
        func call(_ operation: String, revision: String = "") throws -> Transcript.ToolCall {
            let data = try JSONSerialization.data(withJSONObject: ["operation": operation, "path": "A.md", "text": "replacement", "revision": revision, "pageID": ""])
            return .init(id: UUID().uuidString, toolName: "notes", arguments: try GeneratedContent(json: String(decoding: data, as: UTF8.self)))
        }
        _ = await runtime.toolCallDecision(for: try call("read"), in: modelSession)
        _ = await runtime.toolCallDecision(for: try call("replace_markdown", revision: loaded.content.contentRevision), in: modelSession)
        #expect(proposals.count == 1)
        #expect(try await store.knowledgeDocument("A.md").content.markdown == "original")
        try await document.accept(#require(proposals.first))
        #expect(document.content.markdown == "replacement")
    }
    #if canImport(UIKit)
    @Test func finitePageDefaultsAndMissingAssetsNeverRepairTheSource() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let loaded = try await store.create("Page.studycanvas", kind: .notebook)
        let access = KnowledgeToolAccess(store: store)
        let snapshot = try await access.pageSnapshot(path: "Page.studycanvas", pageID: "", region: nil)
        #expect(snapshot.source.region == Rect(x: 0, y: 0, width: loaded.content.pages[0].width, height: loaded.content.pages[0].height))
        #expect(try CanvasRenderer.knowledgeImage(snapshot).size.width > 0)
        var content = loaded.content; content.pages[0].drawingFile = "assets/missing.drawing"
        _ = try await store.save("Page.studycanvas", content: content, expectedRevision: loaded.revision)
        let broken = try await access.pageSnapshot(path: "Page.studycanvas", pageID: "", region: nil)
        #expect(throws: LocalRecognitionError.self) { _ = try CanvasRenderer.knowledgeImage(broken) }
        #expect(try await store.knowledgeDocument("Page.studycanvas").content.pages[0].drawingFile == "assets/missing.drawing")
    }
    @Test func safeImageKeepsInkAboveOpaqueCardsAndPreservesObjectOrder() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let crop = Rect(x: 0, y: 0, width: 200, height: 200)
        let points = [CGPoint(x: 30, y: 100), CGPoint(x: 170, y: 100)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 12, height: 12),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
            path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let blue = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40)).image { output in
            UIColor.blue.setFill(); output.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }
        var content = DocumentContent(kind: .notebook)
        content.pages[0].width = 200; content.pages[0].height = 200
        content.pages[0].drawingFile = "assets/ink.drawing"
        content.pages[0].objects = [
            .init(kind: .text, frame: .init(x: 20, y: 20, width: 160, height: 160), content: "Opaque card"),
            .init(kind: .image, frame: .init(x: 60, y: 120, width: 80, height: 40), content: "assets/blue.png")
        ]
        _ = try await store.save("Layers.studycanvas", content: content, expectedRevision: nil,
                                 assets: ["assets/ink.drawing": ink.dataRepresentation(), "assets/blue.png": try #require(blue.pngData())])
        let captured = try await store.knowledgeSnapshot("Layers.studycanvas", pageID: content.pages[0].id, region: crop, includeAssets: true)
        try FileManager.default.removeItem(at: root) // Rendering must use captured bytes only.
        let image = try CanvasRenderer.knowledgeImage(captured)
        func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
            let cgImage = try #require(image.cgImage)
            let scale = Double(cgImage.width) / crop.width
            let sample = try #require(cgImage.cropping(to: CGRect(x: Double(x) * scale, y: Double(y) * scale, width: 1, height: 1)))
            var bytes = [UInt8](repeating: 255, count: 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try #require(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(sample, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        let line = try pixel(image, x: 100, y: 100)
        #expect(line[0] < 80 && line[1] < 80 && line[2] < 80)
        let card = try pixel(image, x: 30, y: 140)
        #expect(card[0] > 200 && card[2] < 245)
        let orderedImage = try pixel(image, x: 100, y: 140)
        #expect(orderedImage[0] < 30 && orderedImage[1] < 30 && orderedImage[2] > 225)
        let ocrRaster = try LocalHandwritingRecognition.render(captured)
        let ocrImage = try #require(UIImage(data: ocrRaster.pngData))
        let excludedCard = try pixel(ocrImage, x: 30, y: 140)
        #expect(excludedCard[0] > 245 && excludedCard[1] > 245 && excludedCard[2] > 245)
    }
    @Test func safeImageRequiresInfiniteCropAndKeepsAuthoredCardsWithinRasterBudget() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var content = DocumentContent(kind: .infinity)
        let crop = Rect(x: -5000, y: 3000, width: 4096, height: 4096)
        content.pages[0].objects = [.init(kind: .text, frame: .init(x: crop.x, y: crop.y, width: 300, height: 100), content: "authored text")]
        _ = try await store.save("Image.studycanvas", content: content, expectedRevision: nil)
        let access = KnowledgeToolAccess(store: store)
        await #expect(throws: KnowledgeSnapshotError.explicitRegionRequired) {
            _ = try await access.pageSnapshot(path: "Image.studycanvas", pageID: "", region: nil)
        }
        let snapshot = try await access.pageSnapshot(path: "Image.studycanvas", pageID: "", region: crop)
        let image = try CanvasRenderer.knowledgeImage(snapshot)
        #expect(image.size.width <= 2048 && image.size.height <= 2048)
        #expect(image.size.width * image.size.height <= 4_194_304)
        let base = try LocalHandwritingRecognition.render(snapshot)
        #expect(image.pngData() != base.pngData) // Authored card overlay survives, without Vision.
        let ref = try #require(json(await access.citeImage(snapshot))["source_ref"] as? String)
        let citation = try #require(await access.citations(in: "[[\(ref)]]").first)
        #expect(try await KnowledgeToolAccess.validate(citation, store: store).region == crop)
    }
    #endif
}
