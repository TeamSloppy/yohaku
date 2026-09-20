import StudyCore
import StudyIntelligence
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCompactDetail = false
    @State private var showFlashcards = false
    @State private var operation: FileOperation?
    @AppStorage("notebook-page-strip-visible") private var pageStripVisible = true
    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack {
                    sidebar
                        .navigationDestination(isPresented: $showCompactDetail) { detail }
                        .navigationDestination(isPresented: $showFlashcards) { FlashcardsView(workspace: workspace) }
                }
            } else {
                #if targetEnvironment(macCatalyst)
                macNavigation
                #else
                regularNavigation
                #endif
            }
        }
        .sheet(item: $operation) { operation in FileOperationSheet(operation: operation, workspace: workspace) }
        .sheet(isPresented: $workspace.showSettings) { ModelSettingsView(agent: workspace.agent) }
        .fileImporter(isPresented: $workspace.showFolderPicker, allowedContentTypes: [.folder]) { result in
            Task { do { try await workspace.openVault(result.get()) } catch { workspace.error = error.localizedDescription } }
        }
    }
    #if targetEnvironment(macCatalyst)
    private var macNavigation: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 244)
            Divider()
            NavigationStack {
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationDestination(isPresented: $showFlashcards) { FlashcardsView(workspace: workspace) }
            }
        }
    }
    #endif
    private var regularNavigation: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 230, ideal: 244, max: 320)
        } detail: {
            NavigationStack {
                detail
                    .navigationDestination(isPresented: $showFlashcards) { FlashcardsView(workspace: workspace) }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
    @ViewBuilder private var detail: some View {
        #if targetEnvironment(macCatalyst)
        detailContent
            .navigationTitle("Yohaku")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .title) {
                    Text(activeTitle)
                }
                ToolbarItem(placement: .subtitle) {
                    Text(activeSubtitle).foregroundStyle(.secondary)
                }
                ToolbarItem(placement: .primaryAction) { createMenu }
            }
        #else
        detailContent
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if workspace.tabs.isEmpty {
                        Text(activeTitle)
                            .font(.headline)
                    } else {
                        tabStrip
                            .frame(maxWidth: 720)
                    }
                }
                if activeDocumentKind == .notebook {
                    ToolbarItem(placement: .primaryAction) {
                        pageStripToggle
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    createMenu
                    askButton
                }
            }
        #endif
    }
    private var detailContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let error = workspace.error {
                        HStack { Image(systemName: "exclamationmark.triangle"); Text(error).font(.caption); Spacer(); Button("Закрыть") { workspace.error = nil } }
                            .padding(12).background(Color.orange.opacity(0.12))
                    }
                    HStack(spacing: 1) {
                        editor(workspace.activePath)
                        if let secondary = workspace.secondaryPath {
                            Divider()
                            VStack(spacing: 0) {
                                HStack { Text((secondary as NSString).lastPathComponent).font(.caption); Spacer(); Button { workspace.secondaryPath = nil; workspace.persistTabs() } label: { Image(systemName: "xmark") } }.padding(10)
                                editor(secondary)
                            }.frame(maxWidth: .infinity)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if workspace.showAgent && geometry.size.width >= 1200 {
                    Divider(); AgentPanel(workspace: workspace).frame(width: 350)
                }
            }
            .background(Palette.background)
            .sheet(isPresented: Binding(get: { workspace.showAgent && geometry.size.width < 1200 }, set: { workspace.showAgent = $0 })) {
                AgentPanel(workspace: workspace).presentationDetents([.large]).presentationDragIndicator(.visible)
            }
        }
    }
    private var activeTitle: String {
        workspace.activePath.map { ($0 as NSString).deletingPathExtension.components(separatedBy: "/").last ?? $0 } ?? String(localized: "Ваше пространство")
    }
    private var activeSubtitle: String {
        workspace.activePath.map { ($0 as NSString).deletingLastPathComponent } ?? String(localized: "Заметки · Практика · Открытия")
    }
    private var activeDocumentKind: DocumentKind? {
        guard let path = workspace.activePath else { return nil }
        return workspace.sessions[path]?.content.kind
    }
    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(workspace.tabs) { tab in
                    HStack(spacing: 8) {
                        Button { Task { await workspace.open(tab.path) } } label: {
                            HStack(spacing: 7) {
                                Image(systemName: workspace.sessions[tab.path]?.content.kind.symbol ?? "doc")
                                Text((tab.path as NSString).deletingPathExtension.components(separatedBy: "/").last ?? tab.path)
                                    .lineLimit(1)
                                saveStatus(for: tab.path)
                            }
                            .font(.subheadline)
                        }
                        .accessibilityIdentifier("workspace-tab-\(tab.path)")
                        Button { Task { await workspace.close(tab.path) } } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .accessibilityLabel("Закрыть документ")
                        .accessibilityIdentifier("close-workspace-tab-\(tab.path)")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(tab.path == workspace.activePath ? Palette.surface : Color.clear, in: Capsule())
                    .foregroundStyle(tab.path == workspace.activePath ? Palette.accent : .secondary)
                    .contextMenu {
                        Button("Открыть рядом", systemImage: "rectangle.split.2x1") { Task { await workspace.open(tab.path, secondary: true) } }
                        Button("Переместить таб в начало") {
                            if let index = workspace.tabs.firstIndex(where: { $0.path == tab.path }) {
                                workspace.tabs.insert(workspace.tabs.remove(at: index), at: 0)
                                workspace.persistTabs()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityIdentifier("workspace-tabs")
    }
    @ViewBuilder private func saveStatus(for path: String) -> some View {
        if let session = workspace.sessions[path] {
            if session.isSaving {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Сохранение")
            } else if session.isDirty {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .accessibilityLabel("Есть изменения")
            } else if path == workspace.activePath {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .accessibilityLabel("Сохранено")
            }
        }
    }
    private var createMenu: some View {
        Menu { creationMenu(folder: "") } label: { Image(systemName: "plus") }
            .accessibilityLabel("Новый документ")
    }
    private var pageStripToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                pageStripVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.right")
                .foregroundStyle(pageStripVisible ? Palette.accent : .primary)
        }
        .accessibilityLabel(pageStripVisible ? "Скрыть страницы" : "Показать страницы")
        .accessibilityIdentifier("toggle-page-strip")
    }
    private var askButton: some View {
        Button {
            if let path = workspace.activePath { workspace.chatPath = path }
            workspace.showAgent.toggle()
        } label: {
            if horizontalSizeClass == .compact { Image(systemName: "sparkles") }
            else { Label("Спросить", systemImage: "sparkles") }
        }
        .buttonStyle(.bordered).tint(Palette.accent).accessibilityIdentifier("open-agent")
        .accessibilityLabel("Спросить")
    }
    @ViewBuilder private func editor(_ path: String?) -> some View {
        if let path, let session = workspace.sessions[path] {
            DocumentEditor(session: session, workspace: workspace, pageStripVisible: $pageStripVisible)
                .id(path)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 20) {
                Text("余白").font(.system(size: 68, weight: .ultraLight, design: .serif)).foregroundStyle(Palette.accent)
                Text("Место для мысли").font(.largeTitle.bold())
                Text("Откройте заметку или начните с чистого листа.").foregroundStyle(.secondary)
                Menu { creationMenu(folder: "") } label: { Label("Создать документ", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("余白").font(.system(size: 27, weight: .medium, design: .serif)).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) { Text("Y O H A K U").font(.caption.bold()); Text("пространство для учёбы").font(.caption2).foregroundStyle(.secondary) }
            }.padding(22)
            Button {
                showFlashcards = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "brain.head.profile")
                    Text("Сегодня").font(.subheadline.weight(.medium))
                    Spacer()
                    if !workspace.flashcards.dueCards.isEmpty {
                        Text("\(workspace.flashcards.dueCards.count)")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Palette.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.accent)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .accessibilityLabel("Открыть изучение")
            .accessibilityIdentifier("open-flashcards")
            HStack { Text("МОИ ЗАМЕТКИ").font(.caption2.weight(.semibold)).tracking(1.2); Spacer(); Menu { creationMenu(folder: "") } label: { Image(systemName: "plus") } }
                .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.top, 26).padding(.bottom, 10)
                .dropDestination(for: String.self) { paths, _ in
                    return move(paths, into: "")
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if workspace.query.isEmpty {
                        FileTree(workspace: workspace, parent: "", depth: 0, operation: $operation, onOpen: open)
                    } else {
                        ForEach(workspace.searchResults) { entry in
                            Button { open(entry.path) } label: { Label(entry.title, systemImage: entry.kind?.symbol ?? "doc").font(.subheadline).padding(10) }
                        }
                    }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: workspace.isUsingICloud ? "icloud" : "folder")
                    Text(workspace.isUsingICloud ? "iCloud · Yohaku" : (workspace.root?.lastPathComponent ?? "Yohaku")).lineLimit(1)
                    Spacer()
                    Menu {
                        Button("Использовать iCloud", systemImage: "icloud") { Task { await workspace.useDefaultICloudVault() } }
                        Button("Выбрать другую папку", systemImage: "folder") { workspace.showFolderPicker = true }
                    } label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("Выбрать хранилище")
                }
                Button { workspace.showSettings = true } label: { HStack { Image(systemName: "slider.horizontal.3"); Text("Модели и настройки"); Spacer() } }
                    .accessibilityIdentifier("open-model-settings")
            }.font(.caption).foregroundStyle(.secondary).padding(20)
        }
        .background(Palette.surface)
        .searchable(
            text: $workspace.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text("Найти заметку")
        )
        .onChange(of: workspace.query) { _, _ in workspace.search() }
    }
    private func open(_ path: String) {
        Task {
            await workspace.open(path)
            if horizontalSizeClass == .compact { showCompactDetail = true }
        }
    }
    private func move(_ paths: [String], into folder: String) -> Bool {
        guard let source = paths.first else { return false }
        let name = (source as NSString).lastPathComponent
        let destination = folder.isEmpty ? name : (folder as NSString).appendingPathComponent(name)
        guard source != destination, !folder.hasPrefix(source + "/") else { return false }
        Task { await workspace.move(source, to: destination) }
        return true
    }
    @ViewBuilder private func creationMenu(folder: String) -> some View {
        ForEach(DocumentKind.allCases, id: \.self) { kind in
            Button(kind.title, systemImage: kind.symbol) { operation = .init(mode: .create(kind), path: folder) }
        }
        Divider(); Button("Новая папка", systemImage: "folder.badge.plus") { operation = .init(mode: .folder, path: folder) }
    }
}

private struct FileTree: View {
    @Bindable var workspace: WorkspaceModel
    let parent: String
    let depth: Int
    @Binding var operation: FileOperation?
    let onOpen: (String) -> Void
    @State private var expanded: Set<String> = []
    var body: some View {
        ForEach(workspace.entries.filter { $0.parent == parent }) { entry in
            if entry.isDirectory {
                DisclosureGroup(isExpanded: Binding(get: { !expanded.contains(entry.path) }, set: { if $0 { expanded.remove(entry.path) } else { expanded.insert(entry.path) } })) {
                    FileTree(workspace: workspace, parent: entry.path, depth: depth + 1, operation: $operation, onOpen: onOpen)
                } label: { Label(entry.title, systemImage: "folder").font(.subheadline.weight(.medium)) }
                    .padding(.vertical, 7).padding(.horizontal, 9)
                    .contentShape(Rectangle())
                    .draggable(entry.path)
                    .dropDestination(for: String.self) { paths, _ in
                        return move(paths, into: entry.path)
                    }
                    .contextMenu { actions(entry) }
            } else {
                Button { onOpen(entry.path) } label: {
                    Label(entry.title, systemImage: entry.kind?.symbol ?? "doc")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 10)
                        .background(workspace.activePath == entry.path ? Palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.foregroundStyle(workspace.activePath == entry.path ? Palette.accent : .primary)
                    .draggable(entry.path)
                    .contextMenu { actions(entry) }
            }
        }
    }
    private func move(_ paths: [String], into folder: String) -> Bool {
        guard let source = paths.first else { return false }
        let name = (source as NSString).lastPathComponent
        let destination = (folder as NSString).appendingPathComponent(name)
        guard source != destination, !folder.hasPrefix(source + "/") else { return false }
        Task { await workspace.move(source, to: destination) }
        return true
    }
    @ViewBuilder private func actions(_ entry: VaultEntry) -> some View {
        if entry.isDirectory {
            ForEach(DocumentKind.allCases, id: \.self) { kind in Button(kind.title) { operation = .init(mode: .create(kind), path: entry.path) } }
            Button("Новая папка") { operation = .init(mode: .folder, path: entry.path) }
        } else { Button("Открыть рядом") { Task { await workspace.open(entry.path, secondary: true) } } }
        Button("Переименовать / переместить") { operation = .init(mode: .move, path: entry.path) }
        Button("В корзину", role: .destructive) { Task { await workspace.trash(entry.path) } }
    }
}

struct FileOperation: Identifiable {
    enum Mode { case create(DocumentKind), folder, move }
    let id = UUID()
    var mode: Mode
    var path: String
}

private struct FileOperationSheet: View {
    let operation: FileOperation
    var workspace: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Имя или путь внутри хранилища", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                if case .move = operation.mode { Text("Полный путь от корня папки, включая расширение файла.").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        Task {
                            switch operation.mode {
                            case .create(let kind): await workspace.create(name, kind: kind, folder: operation.path)
                            case .folder: await workspace.createFolder((operation.path.isEmpty ? "" : operation.path + "/") + name)
                            case .move: await workspace.move(operation.path, to: name)
                            }
                            dismiss()
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if case .move = operation.mode { name = operation.path } }
        }.presentationDetents([.medium])
    }
    private var title: String {
        switch operation.mode {
        case .create(let kind): String(localized: "Новый документ · ") + kind.title
        case .folder: String(localized: "Новая папка")
        case .move: String(localized: "Переименовать / переместить")
        }
    }
}
