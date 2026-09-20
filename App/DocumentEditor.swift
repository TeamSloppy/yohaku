import PhotosUI
import StudyCanvas
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct DocumentEditor: View {
    @Bindable var session: DocumentSession
    @Bindable var workspace: WorkspaceModel
    @State private var pageID: UUID?
    @State private var handle = CanvasHandle()
    @State private var selecting = false
    @State private var moving = false
    @State private var sourceMode = false
    @State private var paperSettings = false
    @State private var cardKind: CardKind?
    @State private var photo: PhotosPickerItem?
    @State private var importImage = false
    @State private var exported: ExportedImage?
    @State private var selectedText = ""
    @State private var studyDraft: FlashcardDraft?
    @Binding var pageStripVisible: Bool
    @State private var temporaryPageStripVisible = false
    private var tabIndex: Int? { workspace.tabs.firstIndex { $0.path == session.path } }
    private var page: CanvasPage? { session.content.pages.first { $0.id == pageID } ?? session.content.pages.first }
    var body: some View {
        VStack(spacing: 0) {
            if let error = session.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    HStack {
                        if session.conflictPath != nil {
                            Button("Открыть версию с диска") { Task { do { try await session.useDiskVersion() } catch { session.error = error.localizedDescription } } }
                            Button("Открыть сохранённую копию") {
                                guard let path = session.conflictPath else { return }
                                Task { do { try await session.useDiskVersion(); await workspace.refresh(); await workspace.open(path) } catch { session.error = error.localizedDescription } }
                            }
                        } else { Button("Повторить сохранение") { Task { await session.save() } } }
                    }.font(.caption)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.08))
            }
            if session.content.kind == .markdown {
                MarkdownEditor(session: session, sourceMode: sourceMode, cursor: tabIndex.map { workspace.tabs[$0].cursor } ?? 0,
                               onSelection: { text, cursor in selectedText = text; if let i = tabIndex { workspace.tabs[i].cursor = cursor } },
                               onLink: { workspace.openLink($0, source: session.path) }, entries: workspace.entries)
                .padding(.horizontal, 20).background(Palette.surface)
            } else if let page {
                canvasEditor(page)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            editorToolbar
                .padding(.trailing, 16 + editorToolbarPageStripOffset)
                .padding(.bottom, 16)
                .animation(.easeOut(duration: 0.2), value: editorToolbarPageStripOffset)
        }
        .onAppear { pageID = tabIndex.flatMap { workspace.tabs[$0].pageID } ?? session.content.pages.first?.id }
        .onDisappear { Task { await session.save() } }
        .onChange(of: pageStripVisible) { _, _ in temporaryPageStripVisible = false }
        .onChange(of: pageID) { _, new in if let i = tabIndex { workspace.tabs[i].pageID = new; workspace.persistTabs() } }
        .onChange(of: tabIndex.flatMap { workspace.tabs[$0].pageID }) { _, id in if let id { pageID = id } }
        .onChange(of: photo) { _, value in
            Task { do { if let data = try await value?.loadTransferable(type: Data.self) { await addImage(data) } } catch { session.error = error.localizedDescription } }
        }
        .fileImporter(isPresented: $importImage, allowedContentTypes: [.image]) { result in
            Task {
                do {
                    let url = try result.get(), access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    await addImage(try Data(contentsOf: url))
                } catch { session.error = error.localizedDescription }
            }
        }
        .sheet(isPresented: $paperSettings) {
            if let page { PaperSettings(session: session, pageID: page.id) }
        }
        .sheet(item: $cardKind) { kind in
            CardSheet(kind: kind, entries: workspace.entries, source: session.path) { text in
                if session.content.kind == .markdown { session.edit { $0.markdown += "\n" + text + "\n" } }
                else if let page, let i = session.content.pages.firstIndex(where: { $0.id == page.id }) {
                    session.edit { $0.pages[i].objects.append(.init(kind: kind == .text ? .text : .link, content: text)) }
                    handle.surface?.updateContent()
                }
            }
        }
        .sheet(item: $exported) { item in ActivityView(items: [item.image]) }
        .sheet(item: $studyDraft) { draft in
            FlashcardEditorSheet(editor: draft) { card in
                Task { await workspace.flashcards.add(card) }
            }
        }
    }
    private var editorToolbar: some View {
        VStack(spacing: 14) {
            if session.content.kind != .markdown {
                Button { selecting.toggle(); moving = false } label: { Image(systemName: "sparkles") }
                    .accessibilityLabel("Спросить о фрагменте")
                    .foregroundStyle(selecting ? .orange : Palette.accent).accessibilityIdentifier("select-region")
                Button { moving.toggle(); selecting = false } label: { Image(systemName: moving ? "cursorarrow.motionlines" : "square.on.circle") }.accessibilityLabel("Объекты")
                if moving {
                    Button { handle.resizeSelected(by: 1.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    Button { handle.resizeSelected(by: 0.85) } label: { Image(systemName: "minus.magnifyingglass") }
                    Button { handle.removeSelected() } label: { Image(systemName: "trash") }
                }
                Button { handle.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("Отменить")
                Button { handle.redo() } label: { Image(systemName: "arrow.uturn.forward") }.accessibilityLabel("Повторить")
                Button { paperSettings = true } label: { Image(systemName: "square.grid.3x3") }.accessibilityLabel("Бумага")
                Button { handle.home() } label: { Image(systemName: "scope") }.accessibilityLabel("К началу")
            } else {
                Button { sourceMode.toggle() } label: {
                    Image(systemName: sourceMode ? "chevron.left.forwardslash.chevron.right" : "textformat")
                }
                .accessibilityLabel(sourceMode ? "Исходник" : "Live Preview")
                .accessibilityIdentifier("toggle-markdown-source-mode")
                Button {
                    studyDraft = FlashcardDraft(
                        japanese: selectedText,
                        source: StudySource(path: session.path, excerpt: selectedText)
                    )
                } label: { Image(systemName: "rectangle.stack.badge.plus") }
                    .accessibilityLabel("Добавить в изучение")
                    .accessibilityIdentifier("add-selection-to-study")
                    .disabled(selectedText.isEmpty)
                Button { workspace.ask(SourceContext(path: session.path, text: selectedText)) } label: { Image(systemName: "sparkles") }
                    .accessibilityLabel("Спросить о тексте")
                    .disabled(selectedText.isEmpty)
            }
            Divider().frame(width: 24)
            Menu {
                if workspace.backlinks.isEmpty { Text("Обратных ссылок пока нет") }
                ForEach(workspace.backlinks) { entry in
                    Button(entry.title) { Task { await workspace.open(entry.path) } }
                }
            } label: {
                Image(systemName: "link")
            }
            .accessibilityLabel("Связи")
            .accessibilityIdentifier("document-backlinks")
            Menu {
                Button("Из Files", systemImage: "folder") { importImage = true }
                Button("Из буфера", systemImage: "doc.on.clipboard") {
                    if let data = UIPasteboard.general.image?.pngData() { Task { await addImage(data) } }
                    else { session.error = "В буфере обмена нет изображения." }
                }
                Button("Текстовая карточка", systemImage: "text.bubble") { cardKind = .text }
                Button("Ссылка / заметка", systemImage: "link") { cardKind = .link }
            } label: { Image(systemName: "plus.circle") }.accessibilityLabel("Добавить вложение")
            PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo") }.accessibilityLabel("Фото")
            if session.content.kind != .markdown {
                Button {
                    guard let page else { return }
                    Task { do { exported = ExportedImage(image: try await CanvasRenderer.image(session: session, pageID: page.id)) } catch { session.error = error.localizedDescription } }
                } label: { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Экспорт страницы")
            }
        }
        .font(.body)
        .padding(.vertical, 16)
        .frame(width: 52)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.45), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
    private var editorToolbarPageStripOffset: CGFloat {
        guard session.content.kind == .notebook,
              pageStripVisible || temporaryPageStripVisible else { return 0 }
        return 82
    }
    private func canvasEditor(_ page: CanvasPage) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                PencilSurface(session: session, pageID: page.id, selecting: selecting, movingObjects: moving, handle: handle,
                              position: tabIndex.flatMap { workspace.tabs[$0].pagePositions?[page.id.uuidString] } ?? .init(),
                              onPosition: { position in if let i = tabIndex {
                                  workspace.tabs[i].position = position
                                  if workspace.tabs[i].pagePositions == nil { workspace.tabs[i].pagePositions = [:] }
                                  workspace.tabs[i].pagePositions?[page.id.uuidString] = position
                              } },
                              onSelection: { selecting = false; workspace.ask($0) },
                              onOpenLink: { workspace.openLink($0, source: session.path) })
                    .id(page.id)
                if session.content.kind == .notebook && pageStripVisible {
                    Divider()
                    pageStrip.frame(width: 82)
                }
            }

            if session.content.kind == .notebook && !pageStripVisible {
                if temporaryPageStripVisible {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { hideTemporaryPageStrip() }
                        .accessibilityElement()
                        .accessibilityLabel("Закрыть временную панель страниц")
                        .accessibilityIdentifier("dismiss-temporary-page-strip")
                    HStack(spacing: 0) {
                        Divider()
                        pageStrip.frame(width: 82)
                    }
                    .background(Palette.background)
                    .shadow(color: .black.opacity(0.16), radius: 16, x: -6)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .gesture(
                        DragGesture(minimumDistance: 12)
                            .onEnded { value in
                                if value.translation.width > 24 { hideTemporaryPageStrip() }
                            }
                    )
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 28)
                        .accessibilityHidden(true)
                        .gesture(
                            DragGesture(minimumDistance: 12)
                                .onEnded { value in
                                    guard value.translation.width < -24,
                                          abs(value.translation.width) > abs(value.translation.height) else { return }
                                    withAnimation(.easeOut(duration: 0.2)) { temporaryPageStripVisible = true }
                                }
                        )
                }
            }
        }
    }
    private var pageStrip: some View {
        ScrollView {
            VStack(spacing: 16) {
                ForEach(Array(session.content.pages.enumerated()), id: \.element.id) { index, page in
                    Button {
                        handle.surface?.finish()
                        pageID = page.id
                        if temporaryPageStripVisible { hideTemporaryPageStrip() }
                    } label: {
                        VStack(spacing: 5) {
                            PageThumbnail(session: session, page: page).frame(width: 53, height: 75)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(page.id == self.page?.id ? Palette.accent : Color.gray.opacity(0.15), lineWidth: page.id == self.page?.id ? 2 : 1))
                            Text("\(index + 1)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }.contextMenu {
                        Button("Дублировать") { var copy = page; copy.id = UUID(); session.edit { $0.pages.insert(copy, at: index + 1) }; pageID = copy.id }
                        Button("Выше") { session.edit { $0.pages.swapAt(index, max(0, index - 1)) } }.disabled(index == 0)
                        Button("Ниже") { session.edit { $0.pages.swapAt(index, min($0.pages.count - 1, index + 1)) } }.disabled(index == session.content.pages.count - 1)
                        Button("Удалить страницу", role: .destructive) {
                            session.edit { $0.pages.removeAll { $0.id == page.id } }; pageID = session.content.pages.first?.id
                        }.disabled(session.content.pages.count == 1)
                    }
                }
                Button {
                    var new = CanvasPage(); if let page { new.paper = page.paper }
                    session.edit { $0.pages.append(new) }; pageID = new.id
                } label: { Image(systemName: "plus").frame(width: 52, height: 44).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6)) }
                    .accessibilityLabel("Добавить страницу")
                    .accessibilityIdentifier("add-notebook-page")
            }.padding(.vertical, 20)
        }
        .background(Palette.background)
        .accessibilityIdentifier("notebook-page-strip")
    }
    private func hideTemporaryPageStrip() {
        withAnimation(.easeIn(duration: 0.18)) { temporaryPageStripVisible = false }
    }
    private func addImage(_ data: Data) async {
        guard let image = UIImage(data: data) else { session.error = "Не удалось прочитать изображение."; return }
        // Normalize orientation and cap decoded dimensions before keeping the image on canvas.
        let ratio = min(1, 2400 / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let png = normalized.pngData() else { return }
        if session.content.kind == .markdown {
            do {
                let path = try await session.store.importMarkdownAsset(png, extension: "png")
                let link = NoteLinks.relativePath(to: path, from: session.path)
                session.edit { $0.markdown += "\n![Изображение](\(link))\n" }
            } catch { session.error = error.localizedDescription }
        } else if let page, let i = session.content.pages.firstIndex(where: { $0.id == page.id }) {
            let name = session.addAsset(png, extension: "png")
            let frame = Rect(x: 80, y: 180, width: 280, height: 280 * image.size.height / image.size.width)
            session.edit { $0.pages[i].objects.append(.init(kind: .image, frame: frame, content: name)) }
            handle.surface?.updateContent()
        }
    }
}

private struct PageThumbnail: View {
    let session: DocumentSession
    let page: CanvasPage
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFit() } else { Color(uiColor: UIColor(hex: page.paper.background)) } }
            .task(id: "\(page.drawingFile ?? "")\(page.objects)\(page.paper)") {
                image = try? await CanvasRenderer.image(session: session, pageID: page.id, scale: 0.2)
            }
    }
}

enum CardKind: String, Identifiable { case text, link; var id: String { rawValue } }
private struct CardSheet: View {
    let kind: CardKind
    let entries: [VaultEntry]
    let source: String
    let onAdd: (String) -> Void
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(kind == .text ? "Текст" : "URL или относительная ссылка") { TextEditor(text: $text).frame(minHeight: 100) }
                if kind == .link {
                    Section("Другие заметки") {
                        ForEach(entries.filter { !$0.isDirectory && $0.path != source }) { entry in
                            Button(entry.title) { text = NoteLinks.relativePath(to: entry.path, from: source) }
                        }
                    }
                }
            }.navigationTitle(kind == .text ? String(localized: "Карточка") : String(localized: "Ссылка"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Добавить") {
                            if kind == .link && source.hasSuffix(".md") { onAdd("[Ссылка](\(text))") } else { onAdd(text) }; dismiss()
                        }.disabled(text.isEmpty)
                    }
                }
        }
    }
}

private struct PaperSettings: View {
    @Bindable var session: DocumentSession
    let pageID: UUID
    @State private var allPages = false
    @Environment(\.dismiss) private var dismiss
    private var paper: Paper { session.content.pages.first(where: { $0.id == pageID })?.paper ?? Paper() }
    var body: some View {
        NavigationStack {
            Form {
                Picker("Разлиновка", selection: binding(\.pattern)) { ForEach(PaperPattern.allCases, id: \.self) { Text($0.title).tag($0) } }
                VStack(alignment: .leading) { Text("Размер: \(Int(paper.spacing)) pt"); Slider(value: binding(\.spacing), in: 8...84, step: 2) }
                ColorPicker("Цвет бумаги", selection: colorBinding(\.background), supportsOpacity: false)
                ColorPicker("Цвет разлиновки", selection: colorBinding(\.lineColor), supportsOpacity: false)
                Toggle("Применять ко всей тетради", isOn: $allPages)
                    .onChange(of: allPages) { _, value in if value { let paper = paper; session.edit { for i in $0.pages.indices { $0.pages[i].paper = paper } } } }
            }.navigationTitle("Бумага").toolbar { Button("Готово") { dismiss() } }
        }.presentationDetents([.medium, .large])
    }
    private func binding<T>(_ key: WritableKeyPath<Paper, T>) -> Binding<T> {
        Binding(get: { paper[keyPath: key] }, set: { value in
            session.edit { document in for i in document.pages.indices where allPages || document.pages[i].id == pageID { document.pages[i].paper[keyPath: key] = value } }
        })
    }
    private func colorBinding(_ key: WritableKeyPath<Paper, String>) -> Binding<Color> {
        Binding(get: { Color(uiColor: UIColor(hex: paper[keyPath: key])) }, set: { value in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0; UIColor(value).getRed(&r, green: &g, blue: &b, alpha: &a)
            binding(key).wrappedValue = String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
        })
    }
}

private struct ExportedImage: Identifiable { let id = UUID(); var image: UIImage }
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
