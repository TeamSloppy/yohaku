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
    @Test func legacyLocalVaultCopiesIntoEmptyCloudVaultOnce() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = temporary.appendingPathComponent("Local", isDirectory: true)
        let cloud = temporary.appendingPathComponent("Cloud", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: local.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local.appendingPathComponent(".workspace/records"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud.appendingPathComponent(".workspace"), withIntermediateDirectories: true)
        try Data("local note".utf8).write(to: local.appendingPathComponent("Folder/Note.md"))
        try Data("metadata".utf8).write(to: local.appendingPathComponent(".workspace/records/note.json"))

        #expect(try WorkspaceModel.copyLegacyVaultIfNeeded(from: local, to: cloud))
        #expect(try String(contentsOf: cloud.appendingPathComponent("Folder/Note.md"), encoding: .utf8) == "local note")
        #expect(try String(contentsOf: cloud.appendingPathComponent(".workspace/records/note.json"), encoding: .utf8) == "metadata")

        try Data("cloud note".utf8).write(to: cloud.appendingPathComponent("Cloud.md"))
        try Data("new local note".utf8).write(to: local.appendingPathComponent("Other.md"))
        #expect(try !WorkspaceModel.copyLegacyVaultIfNeeded(from: local, to: cloud))
        #expect(!FileManager.default.fileExists(atPath: cloud.appendingPathComponent("Other.md").path))
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
    @Test func infinityEraserPersistencePreservesCanvasObjects() async throws {
        let session = try await document(.infinity)
        let pageID = session.content.pages[0].id
        session.edit { content in
            content.pages[0].objects = [.init(kind: .text, content: "Не стирать карточку")]
        }
        let surface = PencilSurfaceView(session: session, pageID: pageID)

        func stroke(x: CGFloat) -> PKStroke {
            let points = [CGPoint(x: x, y: 4096), CGPoint(x: x + 80, y: 4176)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        }

        surface.canvas.drawing = PKDrawing(strokes: [stroke(x: 4096), stroke(x: 4300)])
        surface.finish()
        surface.canvas.drawing = PKDrawing(strokes: [stroke(x: 4300)])
        surface.finish()

        #expect(session.content.pages[0].objects.map(\.content) == ["Не стирать карточку"])
        let shards = session.content.pages[0].shards
        #expect(shards.count == 1)
        let persisted = try PKDrawing(data: await session.asset(try #require(shards.first).file))
        #expect(persisted.strokes.count == 1)
    }
    @Test func pencilCanvasKeepsDocumentInkInLightAppearance() async throws {
        let session = try await document(.notebook)
        let surface = PencilSurfaceView(session: session, pageID: session.content.pages[0].id)
        let darkHost = UIView()
        darkHost.overrideUserInterfaceStyle = .dark
        darkHost.addSubview(surface)

        #expect(surface.traitCollection.userInterfaceStyle == .light)
        #expect(surface.canvas.traitCollection.userInterfaceStyle == .light)
    }
    @Test func immediatePanCommitsPendingInfiniteInk() async throws {
        let session = try await document(.infinity)
        let surface = PencilSurfaceView(session: session, pageID: session.content.pages[0].id)
        surface.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        surface.layoutIfNeeded()
        let points = [CGPoint(x: 8_192, y: 8_192), CGPoint(x: 8_272, y: 8_272)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        surface.canvas.drawing = PKDrawing(strokes: [
            PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        ])

        surface.canvasViewDidEndUsingTool(surface.canvas)
        surface.scrollViewDidEndDragging(surface.canvas, willDecelerate: false)

        let shard = try #require(session.content.pages[0].shards.first)
        let persisted = try PKDrawing(data: await session.asset(shard.file))
        #expect(persisted.strokes.count == 1)
    }
    @Test func infiniteAimAndOpenFocusLastWrittenStroke() async throws {
        let session = try await document(.infinity)
        let pageID = session.content.pages[0].id
        let surface = PencilSurfaceView(session: session, pageID: pageID)
        surface.frame = CGRect(x: 0, y: 0, width: 1_024, height: 768)
        surface.layoutIfNeeded()
        func stroke(x: CGFloat, created: Date) -> PKStroke {
            let points = [CGPoint(x: x, y: 8_192), CGPoint(x: x + 80, y: 8_272)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: created))
        }
        let old = stroke(x: 8_192, created: Date(timeIntervalSince1970: 1))
        let latest = stroke(x: 9_192, created: Date(timeIntervalSince1970: 2))
        surface.canvas.drawing = PKDrawing(strokes: [old, latest])
        surface.finish()

        let focus = try #require(session.content.pages[0].lastInkBounds)
        #expect(abs(focus.x - (latest.renderBounds.minX - 8_192)) < 1)
        surface.canvas.contentOffset = CGPoint(x: 13_000, y: 13_000)
        surface.goHome()
        #expect(abs(surface.canvas.contentOffset.x - (8_192 - 512)) < 1)
        #expect(abs(surface.canvas.contentOffset.y - (8_192 - 384)) < 1)

        var position = CanvasPosition()
        position.x = -20_000; position.y = -20_000; position.zoom = 1
        let reopened = PencilSurfaceView(session: session, pageID: pageID, position: position)
        reopened.frame = surface.frame
        reopened.layoutIfNeeded()
        #expect(abs(reopened.canvas.contentOffset.x - (8_192 - 512)) < 1)
        #expect(abs(reopened.canvas.contentOffset.y - (8_192 - 384)) < 1)
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
    @Test func markdownLinkHidesAllSyntaxInProductionTextKit() async throws {
        let session = try await document(.markdown)
        let source = "[Открыть тетрадь](Практика.studycanvas)\n"
        session.edit { $0.markdown = source }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: source.utf16.count, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let container = MarkdownEditorContainer()
        let view = container.textView
        coordinator.attach(to: view, container: container)
        view.delegate = coordinator
        view.text = source
        view.selectedRange = NSRange(location: (source as NSString).length, length: 0)
        coordinator.style(view)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 200)
        view.layoutIfNeeded()

        let title = (source as NSString).range(of: "Открыть тетрадь")
        let prefix = NSRange(location: 0, length: title.location)
        let suffix = NSRange(location: NSMaxRange(title), length: (source as NSString).length - NSMaxRange(title) - 1)
        for range in [prefix, suffix] {
            let font = try #require(view.attributedText.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
            let color = try #require(view.attributedText.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor)
            #expect(font.pointSize < 1)
            #expect(color.cgColor.alpha == 0)
        }
        #expect(view.text == source)
        #expect(view.textLayoutManager == nil)
    }
    @Test func changingPagesFlushesThePreviousDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = VaultStore(root: root)
        try await store.prepare()
        let first = try await store.create("First.md", kind: .markdown, text: "old")
        try await store.create("Second.md", kind: .markdown, text: "second")
        let session = DocumentSession(path: "First.md", loaded: first, store: store)
        let workspace = WorkspaceModel()
        workspace.store = store
        workspace.entries = try await store.list()
        workspace.sessions["First.md"] = session
        workspace.tabs = [.init(path: "First.md")]
        workspace.activePath = "First.md"
        session.edit { $0.markdown = "new" }

        await workspace.open("Second.md")

        #expect(try await store.load("First.md").content.markdown == "new")
        #expect(!session.isDirty)
        #expect(workspace.activePath == "Second.md")
    }
    @Test func damagedDirtyPackageCanStillBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VaultStore(root: root)
        try await store.prepare()
        let path = "Повреждённый.studycanvas"
        let loaded = try await store.create(path, kind: .notebook)
        let session = DocumentSession(path: path, loaded: loaded, store: store)
        session.edit { $0.pages[0].objects.append(.init(kind: .text, content: "Несохранённый текст")) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(path).appendingPathComponent("manifest.json"))

        let workspace = WorkspaceModel()
        workspace.store = store
        workspace.entries = try await store.list()
        workspace.sessions[path] = session
        workspace.tabs = [.init(path: path)]
        workspace.activePath = path
        workspace.chatPath = path

        await workspace.trash(path)

        #expect(workspace.error == nil)
        #expect(!workspace.entries.contains { $0.path == path })
        #expect(workspace.sessions[path] == nil)
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.activePath == nil)
        #expect(workspace.chatPath == nil)
    }
    @Test func selectionCallbackBeforeChangeDoesNotRestoreOldMarkdown() async throws {
        let session = try await document(.markdown)
        let source = "[Открыть тетрадь](Практика.studycanvas)\n\nСтрока"
        session.edit { $0.markdown = source }
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: source.utf16.count, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let view = MarkdownTextView(usingTextLayoutManager: false)
        coordinator.attach(to: view)
        view.delegate = coordinator
        view.text = source
        view.selectedRange = NSRange(location: (source as NSString).length, length: 0)
        coordinator.style(view)

        view.textStorage.append(NSAttributedString(string: " новая"))
        view.selectedRange = NSRange(location: view.textStorage.length, length: 0)
        coordinator.textViewDidChangeSelection(view)
        coordinator.textViewDidChange(view)

        #expect(session.content.markdown == source + " новая")
        #expect(coordinator.baseSource == source + " новая")
        #expect(view.text == source + " новая")
        await session.save()
        #expect(try await session.store.load(session.path).content.markdown == source + " новая")
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
    @Test func markdownSlashCommandsParseFilterAndProvideTemplates() throws {
        let query = try #require(MarkdownEditingSupport.slashQuery(in: "  /tab", selection: NSRange(location: 6, length: 0)))
        #expect(query.text == "tab")
        #expect(query.replacementRange == NSRange(location: 2, length: 4))
        #expect(MarkdownEditingSupport.slashQuery(in: "текст /tab", selection: NSRange(location: 10, length: 0))?.text == "tab")
        #expect(MarkdownEditingSupport.slashQuery(in: "текст/tab", selection: NSRange(location: 9, length: 0)) == nil)
        #expect(MarkdownEditingSupport.slashCommands(matching: "tab").map(\.id) == ["table"])
        #expect(MarkdownEditingSupport.slashCommands(matching: "").prefix(3).map(\.id) == ["checkbox", "link", "table"])
        #expect(MarkdownEditingSupport.slashCommands.first { $0.id == "checkbox" }?.insertion == "- [ ] ")
        #expect(MarkdownEditingSupport.slashCommands.first { $0.id == "link" }?.insertion == "[текст](url)")
        #expect(MarkdownEditingSupport.slashCommands.first { $0.id == "table" }?.insertion.contains("| --- | --- |") == true)
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
    @Test func markdownCoordinatorShowsSlashPopupAndInsertsTable() async throws {
        let session = try await document(.markdown)
        let editor = MarkdownEditor(session: session, sourceMode: false, cursor: 0, onSelection: { _, _ in }, onLink: { _ in })
        let coordinator = editor.makeCoordinator()
        let container = MarkdownEditorContainer()
        let view = container.textView
        coordinator.attach(to: view, container: container)
        view.delegate = coordinator
        view.text = ""
        coordinator.style(view)
        container.frame = CGRect(x: 0, y: 0, width: 500, height: 500)

        view.textStorage.replaceCharacters(in: view.selectedRange, with: "/tab")
        view.selectedRange = NSRange(location: 4, length: 0)
        coordinator.textViewDidChange(view)
        container.layoutIfNeeded()

        func commandButton(_ root: UIView) -> UIButton? {
            if let button = root as? UIButton, button.accessibilityIdentifier == "markdown-slash-command-table" { return button }
            return root.subviews.lazy.compactMap(commandButton).first
        }
        let button = try #require(commandButton(container))
        button.sendActions(for: .touchUpInside)

        #expect(session.content.markdown == "| Колонка 1 | Колонка 2 |\n| --- | --- |\n|  |  |")
        #expect(view.selectedRange == NSRange(location: 2, length: 9))
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
