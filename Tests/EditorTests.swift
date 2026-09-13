import PencilKit
import StudyCanvas
import StudyCore
import Testing
import UIKit
@testable import Yohaku

@MainActor struct EditorTests {
    private func document(_ kind: DocumentKind) async throws -> DocumentSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(root: root); try await store.prepare()
        let path = "Test." + kind.fileExtension
        return DocumentSession(path: path, loaded: try await store.create(path, kind: kind), store: store)
    }
    @Test func regionImageCompositesObjectsAtWorldCoordinates() async throws {
        let session = try await document(.notebook)
        let red = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { renderer in
            UIColor.red.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let name = session.addAsset(try #require(red.pngData()), extension: "png")
        session.edit { content in
            content.pages[0].paper.pattern = .plain; content.pages[0].paper.background = "FFFFFF"
            content.pages[0].objects = [.init(kind: .image, frame: Rect(x: 110, y: 110, width: 50, height: 50), content: name)]
        }
        let id = session.content.pages[0].id
        let image = try await CanvasRenderer.image(session: session, pageID: id, region: CGRect(x: 100, y: 100, width: 100, height: 100), scale: 1)
        #expect(image.size == CGSize(width: 100, height: 100))
        let sample = pixel(image, x: 20, y: 20), background = pixel(image, x: 90, y: 90)
        #expect(sample[0] > 240 && sample[1] < 10 && sample[2] < 10)
        #expect(background[0] > 240 && background[1] > 240 && background[2] > 240)
    }
    @Test func infinityExportDoesNotLoadDistantShards() async throws {
        let session = try await document(.infinity)
        let points = [CGPoint(x: -20, y: 50), CGPoint(x: 1100, y: 50)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        let file = session.addAsset(drawing.dataRepresentation(), extension: "drawing")
        session.edit { content in
            content.pages[0].shards = [.init(file: file, bounds: Rect(drawing.bounds))]
            for index in 1...1000 { content.pages[0].shards.append(.init(file: "unloaded-\(index).drawing", bounds: Rect(x: Double(index) * 5000, y: 5000))) }
        }
        let image = try await CanvasRenderer.image(session: session, pageID: session.content.pages[0].id, region: CGRect(x: 1000, y: 0, width: 100, height: 100))
        #expect(image.size.width == 100)
        #expect(session.error == nil)
    }
    @Test func markdownInitialStylingAndEditingPreserveSource() async throws {
        let session = try await document(.markdown)
        session.edit { $0.markdown = "# 日本語\n\n**単語** と *文法*\n" }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: 0, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true); view.delegate = coordinator
        view.text = session.content.markdown; view.selectedRange = NSRange(location: 0, length: 0)
        coordinator.style(view)
        #expect(view.text == session.content.markdown)
        view.text += "こんにちは 🌸"
        coordinator.textViewDidChange(view)
        #expect(session.content.markdown.hasSuffix("こんにちは 🌸"))
        await session.save()
        #expect(try await session.store.load(session.path).content.markdown == session.content.markdown)
    }
    @Test func markdownLivePreviewRendersCheckedAndUncheckedTasks() async throws {
        let session = try await document(.markdown)
        session.edit { $0.markdown = """
        # Место для мысли

        **Yohaku · 余白** — свободное пространство на странице.

        Здесь можно писать, собирать знания и задавать вопросы.

        ## Сегодня

        - [x] Готовый пункт
        - [ ] Следующий пункт
        - [ ] Последний пункт
        """ }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: session.content.markdown.utf16.count, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.delegate = coordinator
        view.text = session.content.markdown
        view.selectedRange = NSRange(location: session.content.markdown.utf16.count, length: 0)
        coordinator.style(view)

        let taskButtons = view.subviews.compactMap { $0 as? UIButton }
        #expect(taskButtons.count == 3)
        #expect(taskButtons.contains { $0.accessibilityValue == "Выполнено" })
        #expect(taskButtons.contains { $0.accessibilityValue == "Не выполнено" })
        if let textLayoutManager = view.textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }
        view.layoutIfNeeded()
        let firstTitle = "Готовый пункт" as NSString
        let titleLocation = (view.text as NSString).range(of: firstTitle as String).location
        let titlePosition = try #require(view.position(from: view.beginningOfDocument, offset: titleLocation))
        let titleEnd = try #require(view.position(from: titlePosition, offset: 1))
        let titleRange = try #require(view.textRange(from: titlePosition, to: titleEnd))
        let titleRect = view.firstRect(for: titleRange)
        let firstButton = try #require(taskButtons.first { $0.accessibilityLabel == firstTitle as String })
        #expect(abs(firstButton.frame.midY - titleRect.midY) < 1)
        let markerFont = try #require(view.attributedText.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        #expect(markerFont.pointSize < 1)
        let completedButton = try #require(taskButtons.first { $0.accessibilityValue == "Выполнено" })
        completedButton.sendActions(for: .touchUpInside)
        #expect(session.content.markdown.hasPrefix("- [ ] Готовый пункт"))
    }
    @Test func proposalRejectsUnsavedUserEdits() async throws {
        let session = try await document(.markdown)
        let proposal = ChangeProposal(action: .replaceMarkdown, path: session.path, baseRevision: session.content.contentRevision, text: "agent")
        session.edit { $0.markdown = "user" }
        await #expect(throws: StudyError.self) { try await session.accept(proposal) }
        #expect(session.content.markdown == "user")
    }
    private func pixel(_ image: UIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.translateBy(x: -CGFloat(x), y: CGFloat(y) - image.size.height + 1)
            context.draw(image.cgImage!, in: CGRect(origin: .zero, size: image.size))
        }
        return bytes
    }
}
