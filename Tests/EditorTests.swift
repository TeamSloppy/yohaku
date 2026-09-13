import PencilKit
import StudyCanvas
import StudyCore
import Testing
import UIKit
@testable import Yohaku

@MainActor @Suite(.serialized) struct EditorTests {
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
        session.edit { $0.markdown = "- [x] Готовый пункт\n- [ ] Следующий пункт\n" }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: 2, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = UITextView(usingTextLayoutManager: true)
        view.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.delegate = coordinator
        view.text = session.content.markdown
        view.selectedRange = NSRange(location: 2, length: 0)
        coordinator.style(view)

        let taskButtons = view.subviews.compactMap { $0 as? UIButton }
        #expect(taskButtons.count == 2)
        #expect(taskButtons.contains { $0.accessibilityIdentifier == "markdown-task-checked" })
        #expect(taskButtons.contains { $0.accessibilityIdentifier == "markdown-task-unchecked" })
        let markerFont = try #require(view.attributedText.attribute(.font, at: 2, effectiveRange: nil) as? UIFont)
        #expect(markerFont.pointSize < 1)
        let completedButton = try #require(taskButtons.first { $0.accessibilityIdentifier == "markdown-task-checked" })
        completedButton.sendActions(for: .touchUpInside)
        #expect(session.content.markdown.hasPrefix("- [ ] Готовый пункт"))
    }
    @Test func markdownTaskControlsFollowFinalLayoutAndScrolling() async throws {
        let session = try await document(.markdown)
        session.edit { $0.markdown = """
        # Место для мысли

        **Yohaku · 余白** — свободное пространство на странице.

        Здесь можно писать, собирать знания и задавать вопросы.

        ## Сегодня

        - [ ] Открыть тетрадь
        - [ ] Спросить агента
        - [ ] Сохранить объяснение
        """ }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: session.content.markdown.utf16.count, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = MarkdownTextView(usingTextLayoutManager: true)
        coordinator.attach(to: view)
        view.delegate = coordinator
        view.text = session.content.markdown
        view.selectedRange = NSRange(location: session.content.markdown.utf16.count, length: 0)
        coordinator.style(view)

        view.frame = CGRect(x: 0, y: 0, width: 500, height: 300)
        view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        if let textLayoutManager = view.textLayoutManager {
            textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        }
        view.layoutIfNeeded()

        let taskButtons = view.subviews.compactMap { $0 as? UIButton }
        #expect(taskButtons.count == 3)
        let firstTitle = "Открыть тетрадь"
        let titleLocation = (view.text as NSString).range(of: firstTitle).location
        let titlePosition = try #require(view.position(from: view.beginningOfDocument, offset: titleLocation))
        let titleEnd = try #require(view.position(from: titlePosition, offset: 1))
        let titleRange = try #require(view.textRange(from: titlePosition, to: titleEnd))
        let firstButton = try #require(taskButtons.first { $0.accessibilityLabel == firstTitle })
        #expect(abs(firstButton.convert(firstButton.bounds, to: view).midY - view.firstRect(for: titleRange).midY) < 1)

        view.contentOffset = CGPoint(x: 0, y: 80)
        coordinator.scrollViewDidScroll(view)
        #expect(abs(firstButton.convert(firstButton.bounds, to: view).midY - view.firstRect(for: titleRange).midY) < 1)
    }
    @Test func markdownLinkCompletionFindsFiltersAndReplacesBracketQuery() throws {
        let source = "Привет [[Пра]]"
        let closing = (source as NSString).range(of: "]]").location
        let query = try #require(MarkdownEditingSupport.linkQuery(in: source, selection: NSRange(location: closing, length: 0)))
        #expect(query.text == "Пра")
        #expect((source as NSString).substring(with: query.replacementRange) == "[[Пра]]")

        let entries = [
            VaultEntry(path: "日本語", isDirectory: true),
            VaultEntry(path: "日本語/Практика.studycanvas", isDirectory: false, kind: .notebook),
            VaultEntry(path: "日本語/Начало.md", isDirectory: false, kind: .markdown),
            VaultEntry(path: "Практика.md", isDirectory: false, kind: .markdown)
        ]
        let suggestions = MarkdownEditingSupport.suggestions(entries: entries, query: "пра", currentPath: "日本語/Начало.md")
        #expect(suggestions.map(\.path) == ["Практика.md", "日本語/Практика.studycanvas"])
        #expect(MarkdownEditingSupport.link(to: entries[1], from: "日本語/Начало.md") == "[Практика](%D0%9F%D1%80%D0%B0%D0%BA%D1%82%D0%B8%D0%BA%D0%B0.studycanvas)")
        #expect(MarkdownEditingSupport.link(to: entries[0], from: "日本語/Начало.md") == "[日本語](./)")
    }
    @Test func markdownTypingClosesPairsWrapsSelectionsAndStepsOverClosers() throws {
        let first = try #require(MarkdownEditingSupport.automaticEdit(in: "", range: NSRange(location: 0, length: 0), replacement: "["))
        #expect(first.replacementText == "[]")
        #expect(first.selection == NSRange(location: 1, length: 0))

        let second = try #require(MarkdownEditingSupport.automaticEdit(in: "[]", range: first.selection, replacement: "["))
        #expect(second.replacementText == "[]")
        let nested = ("[]" as NSString).replacingCharacters(in: second.replacementRange, with: second.replacementText)
        #expect(nested == "[[]]")
        #expect(MarkdownEditingSupport.linkQuery(in: nested, selection: second.selection)?.text == "")

        let skip = try #require(MarkdownEditingSupport.automaticEdit(in: nested, range: second.selection, replacement: "]"))
        #expect(!skip.changesText)
        #expect(skip.selection == NSRange(location: 3, length: 0))

        let wrapped = try #require(MarkdownEditingSupport.automaticEdit(in: "текст", range: NSRange(location: 0, length: 5), replacement: "\""))
        #expect(wrapped.replacementText == "\"текст\"")
        #expect(wrapped.selection == NSRange(location: 1, length: 5))
    }
    @Test func markdownCoordinatorShowsFilteredCompletionButtons() async throws {
        let session = try await document(.markdown)
        let entry = VaultEntry(path: "日本語/Практика.studycanvas", isDirectory: false, kind: .notebook)
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: 0, onSelection: { _, _ in }, onLink: { _ in }, entries: [entry])
        let coordinator = editor.makeCoordinator()
        let container = MarkdownEditorContainer()
        let view = container.textView
        coordinator.attach(to: view, container: container)
        view.delegate = coordinator
        view.text = ""
        coordinator.style(view)
        container.frame = CGRect(x: 0, y: 0, width: 500, height: 300)

        func type(_ text: String) {
            let range = view.selectedRange
            if coordinator.textView(view, shouldChangeTextIn: range, replacementText: text) {
                view.textStorage.replaceCharacters(in: range, with: text)
                view.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
                coordinator.textViewDidChange(view)
            }
        }
        type("["); type("["); type("прак")
        container.layoutIfNeeded()

        func containsSuggestion(_ root: UIView) -> Bool {
            root.accessibilityIdentifier == "markdown-link-completion-日本語/Практика.studycanvas" || root.subviews.contains(where: containsSuggestion)
        }
        #expect(view.text == "[[прак]]")
        #expect(containsSuggestion(container))
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
