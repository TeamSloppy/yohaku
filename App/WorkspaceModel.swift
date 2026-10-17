import Foundation
import Observation
import StudyCanvas
import StudyCore
import StudyIntelligence
import UIKit

struct DocumentTab: Codable, Identifiable, Equatable {
    var path: String
    var pageID: UUID?
    var position = CanvasPosition()
    var cursor = 0
    var pagePositions: [String: CanvasPosition]?
    var id: String { path }
}

@MainActor @Observable final class WorkspaceModel {
    nonisolated static let iCloudContainerIdentifier = "iCloud.team.sloppy.yohaku"

    var store: VaultStore?
    var root: URL?
    var entries: [VaultEntry] = []
    var tabs: [DocumentTab] = []
    var activePath: String?
    var secondaryPath: String?
    var sessions: [String: DocumentSession] = [:]
    var error: String?
    var busy = false
    var showAgent = false
    var pendingContext: SourceContext?
    var sourceNavigation: SourceNavigationRequest?
    var chatPath: String?
    var showSettings = false
    var showFolderPicker = false
    var isUsingICloud = false
    var query = ""
    var searchResults: [VaultEntry] = []
    var knowledgeResults: [KnowledgeSearchHit] = []
    var knowledgeCoverage: KnowledgeSearchCoverage?
    var knowledgeSearchError: String?
    var knowledgeSearching = false
    var knowledgeNextCursor: String?
    var backlinks: [VaultEntry] = []
    let agent = AgentSession()
    let flashcards = FlashcardStore { cards in await StudyCompanion.shared.updateCards(cards) }
    private var accessURL: URL?
    private var presenter: VaultPresenter?
    private var starting = false
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var refreshing = false
    private var vaultID: String?
    private var navigationGeneration = UUID()
    private var defaultsKey: String { "workspace-tabs-" + (vaultID ?? root?.path ?? "") }

    func start() async {
        guard !starting, store == nil else { return }; starting = true
        defer { starting = false }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            do {
                try await openVault(URL.temporaryDirectory.appendingPathComponent("UITest-\(UUID())"), remember: false)
                try await seed()
                if ProcessInfo.processInfo.arguments.contains("--canvas-maintenance-fixture"), let store {
                    let path = "日本語/Практика.studycanvas"
                    let loaded = try await store.load(path)
                    try await store.save(path, content: loaded.content, expectedRevision: loaded.revision,
                        assets: ["assets/obsolete.drawing": Data(repeating: 1, count: 128 * 1024)])
                }
            } catch { self.error = error.localizedDescription }
            return
        }
        let legacyLocal = Self.legacyLocalVaultURL
        if let bookmark = UserDefaults.standard.data(forKey: "vault-bookmark") {
            do {
                var stale = false
                #if targetEnvironment(macCatalyst)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkResolutionOptions = []
                #endif
                let url = try URL(resolvingBookmarkData: bookmark, options: options, bookmarkDataIsStale: &stale)
                if !Self.isSameLocation(url, legacyLocal) {
                    try await openVault(url)
                    return
                }
                // Older versions remembered their automatic on-device vault as if
                // the user had explicitly selected it. Ignore that bookmark so the
                // upgraded app can move to its iCloud container automatically.
                UserDefaults.standard.removeObject(forKey: "vault-bookmark")
            } catch {
                self.error = String.localizedStringWithFormat(
                    String(localized: "Папка недоступна: %@. Выберите её повторно."),
                    error.localizedDescription
                )
                showFolderPicker = true
            }
        }
        if let cloud = await Self.defaultICloudVaultURL() {
            do {
                try Self.copyLegacyVaultIfNeeded(from: legacyLocal, to: cloud)
                try await openVault(cloud, remember: false, iCloud: true)
                if entries.isEmpty { try await seed() }
                return
            } catch {
                self.error = String.localizedStringWithFormat(
                    String(localized: "Не удалось открыть iCloud: %@. Yohaku продолжит работу локально."),
                    error.localizedDescription
                )
            }
        } else {
            self.error = String(localized: "iCloud Drive недоступен. Войдите в iCloud и включите iCloud Drive; до этого Yohaku сохранит заметки только на устройстве.")
        }
        do {
            try await openVault(legacyLocal, remember: false, iCloud: false)
            if entries.isEmpty { try await seed() }
        } catch { self.error = error.localizedDescription }
    }
    func openVault(_ url: URL, remember: Bool = true, iCloud: Bool? = nil) async throws {
        resetKnowledgeSearch()
        navigationGeneration = UUID(); sourceNavigation = nil
        agent.cancel(); await saveAll()
        guard !sessions.values.contains(where: { $0.isDirty }) else { throw StudyError.modelUnavailable("Сначала сохраните изменения или разрешите конфликт в текущем хранилище.") }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        accessURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { accessURL = url } else { accessURL = nil }
        let store = VaultStore(root: url); try await store.prepare()
        self.store = store; root = url; vaultID = try await store.identifier(); sessions = [:]; activePath = nil; secondaryPath = nil
        sourceNavigation = nil
        await flashcards.open(vaultRoot: url)
        isUsingICloud = iCloud ?? Self.isUbiquitous(url)
        #if targetEnvironment(macCatalyst)
        let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
        #else
        let bookmarkOptions: URL.BookmarkCreationOptions = .minimalBookmark
        #endif
        if remember, let bookmark = try? url.bookmarkData(options: bookmarkOptions, includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "vault-bookmark")
        }
        entries = try await store.list()
        do { try await store.reconcileKnowledge() } catch { knowledgeSearchError = error.localizedDescription }
        let presenter = VaultPresenter(url: url, changed: { [weak self] in await self?.refresh() }, moved: { [weak self] old, new in await self?.externalMove(old, to: new) })
        self.presenter = presenter; NSFileCoordinator.addFilePresenter(presenter)
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) {
            tabs = saved.tabs.filter { tab in entries.contains { $0.path == tab.path } }
            for tab in tabs {
                do {
                    guard try await store.isAvailableLocally(tab.path) else { continue }
                    try await load(tab.path)
                }
                catch { self.error = String.localizedStringWithFormat(String(localized: "Не удалось открыть %@: %@"), tab.path, error.localizedDescription) }
            }
            activePath = saved.active.flatMap { sessions[$0] != nil ? $0 : nil } ?? tabs.first(where: { sessions[$0.path] != nil })?.path
            secondaryPath = saved.secondary.flatMap { sessions[$0] != nil ? $0 : nil }
        } else { tabs = [] }
        if !query.isEmpty { search() }
    }

    func useDefaultICloudVault() async {
        guard let cloud = await Self.defaultICloudVaultURL() else {
            error = String(localized: "iCloud Drive недоступен. Войдите в iCloud и включите iCloud Drive.")
            return
        }
        do {
            try Self.copyLegacyVaultIfNeeded(from: Self.legacyLocalVaultURL, to: cloud)
            try await openVault(cloud, remember: false, iCloud: true)
            UserDefaults.standard.removeObject(forKey: "vault-bookmark")
            if entries.isEmpty { try await seed() }
        } catch {
            self.error = String.localizedStringWithFormat(String(localized: "Не удалось открыть iCloud: %@"), error.localizedDescription)
        }
    }

    nonisolated static var legacyLocalVaultURL: URL {
        URL.documentsDirectory.appendingPathComponent("Yohaku", isDirectory: true)
    }

    nonisolated static func defaultICloudVaultURL() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            FileManager.default
                .url(forUbiquityContainerIdentifier: iCloudContainerIdentifier)?
                .appendingPathComponent("Documents", isDirectory: true)
        }.value
    }

    nonisolated static func isSameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true
    }

    /// Preserve an existing on-device vault when upgrading to the iCloud-first
    /// version. The local copy remains as a recovery copy; migration only runs
    /// while the cloud document scope has no user-visible content.
    @discardableResult
    nonisolated static func copyLegacyVaultIfNeeded(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        guard fileManager.fileExists(atPath: source.path) else { return false }
        let sourceItems = try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" }
        guard !sourceItems.isEmpty else { return false }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let cloudItems = try fileManager.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != ".DS_Store" && $0.lastPathComponent != ".workspace" }
        guard cloudItems.isEmpty else { return false }

        for sourceItem in sourceItems {
            let target = destination.appendingPathComponent(sourceItem.lastPathComponent)
            try copyMissingItem(from: sourceItem, to: target, fileManager: fileManager)
        }
        return true
    }

    nonisolated private static func copyMissingItem(from source: URL, to target: URL, fileManager: FileManager) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) else { return }
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.copyItem(at: source, to: target)
            return
        }
        guard isDirectory.boolValue else { return }
        for child in try fileManager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try copyMissingItem(
                from: child,
                to: target.appendingPathComponent(child.lastPathComponent),
                fileManager: fileManager
            )
        }
    }
    private struct SavedTabs: Codable { var tabs: [DocumentTab]; var active: String?; var secondary: String? }
    func persistTabs() {
        if let data = try? JSONEncoder().encode(SavedTabs(tabs: tabs, active: activePath, secondary: secondaryPath)) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
    func refresh() async {
        guard let store, !refreshing else { return }; refreshing = true; defer { refreshing = false }
        do {
            entries = try await store.list()
            guard self.store === store else { return }
            for session in sessions.values { await session.refresh() }
            guard self.store === store else { return }
            do { try await store.reconcileKnowledge() } catch { knowledgeSearchError = error.localizedDescription }
            guard self.store === store else { return }
            invalidateSourceNavigation()
            if let path = activePath { backlinks = try await store.backlinks(to: path) }
            if !query.isEmpty { search() }
        } catch { self.error = error.localizedDescription }
    }
    private func resetKnowledgeSearch() {
        searchTask?.cancel(); searchGeneration = UUID()
        knowledgeResults = []; searchResults = []; knowledgeCoverage = nil
        knowledgeNextCursor = nil; knowledgeSearchError = nil; knowledgeSearching = false
    }
    func search(loadMore: Bool = false) {
        searchTask?.cancel()
        let query = query, generation = UUID(), cursor = loadMore ? knowledgeNextCursor : nil
        searchGeneration = generation
        if !loadMore { knowledgeResults = []; searchResults = []; knowledgeCoverage = nil; knowledgeNextCursor = nil }
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let store else {
            knowledgeSearching = false; return
        }
        knowledgeSearching = true; knowledgeSearchError = nil
        searchTask = Task {
            defer { if searchGeneration == generation { knowledgeSearching = false } }
            do {
                if !loadMore { try await Task.sleep(for: .milliseconds(200)) }
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                let page = try await store.searchKnowledge(.init(query: query, cursor: cursor))
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                knowledgeResults = loadMore ? knowledgeResults + page.hits : page.hits
                knowledgeCoverage = page.coverage; knowledgeNextCursor = page.nextCursor
            } catch is CancellationError {} catch {
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                knowledgeSearchError = error.localizedDescription
                // Keep the established text search usable while the disposable index is unavailable.
                let fallback = (try? await store.search(query)) ?? []
                guard searchIsCurrent(store, query: query, generation: generation) else { return }
                searchResults = fallback; knowledgeNextCursor = nil
            }
        }
    }
    private func searchIsCurrent(_ store: VaultStore, query: String, generation: UUID) -> Bool {
        !Task.isCancelled && self.store === store && self.query == query && searchGeneration == generation
    }
    func rebuildKnowledgeIndex() {
        searchTask?.cancel(); let generation = UUID(); searchGeneration = generation
        guard let store else { return }
        knowledgeSearching = true
        searchTask = Task {
            do {
                try await store.rebuildKnowledge()
                guard !Task.isCancelled, self.store === store, searchGeneration == generation else { return }
                knowledgeSearching = false; search()
            } catch {
                guard !Task.isCancelled, self.store === store, searchGeneration == generation else { return }
                knowledgeSearching = false; knowledgeSearchError = error.localizedDescription
            }
        }
    }
    func open(_ path: String, secondary: Bool = false, pageID: UUID? = nil) async {
        let generation = UUID(); navigationGeneration = generation
        if !secondary { sourceNavigation = nil }
        await openDocument(path, secondary: secondary, pageID: pageID, generation: generation)
    }
    private func openDocument(_ path: String, secondary: Bool, pageID: UUID?, generation: UUID) async {
        do {
            if !secondary, let activePath, activePath != path {
                await sessions[activePath]?.save()
            }
            guard navigationGeneration == generation else { return }
            try await load(path)
            guard navigationGeneration == generation else { return }
            if !tabs.contains(where: { $0.path == path }) { tabs.append(DocumentTab(path: path, pageID: pageID)) }
            else if let pageID, let i = tabs.firstIndex(where: { $0.path == path }) { tabs[i].pageID = pageID }
            if secondary { secondaryPath = path } else { activePath = path }
            let links = try await store?.backlinks(to: path) ?? []
            guard navigationGeneration == generation else { return }
            backlinks = links; persistTabs()
        } catch { self.error = error.localizedDescription }
    }
    func open(_ source: SourceContext) async {
        let generation = UUID(); navigationGeneration = generation; sourceNavigation = nil
        if let region = source.region,
           (![region.x, region.y, region.width, region.height, region.x + region.width, region.y + region.height].allSatisfy(\.isFinite) || region.width <= 0 || region.height <= 0) {
            error = String(localized: "Некорректная область источника.")
            return
        }
        do {
            try await load(source.path)
            guard navigationGeneration == generation else { return }
            guard let session = sessions[source.path] else { return }
            let targetPage = source.pageID ?? tabs.first(where: { $0.path == source.path })?.pageID ?? session.content.pages.first?.id
            if let targetPage, !session.content.pages.contains(where: { $0.id == targetPage }) {
                error = String(localized: "Страница источника больше не существует.")
                return
            }
            await openDocument(source.path, secondary: false, pageID: targetPage, generation: generation)
            if navigationGeneration == generation, let targetPage, activePath == source.path, sessions[source.path] === session {
                sourceNavigation = .init(path: source.path, pageID: targetPage, region: source.region)
            }
        } catch { self.error = error.localizedDescription }
    }
    func completeSourceNavigation(_ id: UUID) {
        guard sourceNavigation?.id == id else { return }
        sourceNavigation = nil
        persistTabs()
    }
    func invalidateSourceNavigation() {
        guard let request = sourceNavigation else { return }
        if sessions[request.path]?.content.pages.contains(where: { $0.id == request.pageID }) != true {
            sourceNavigation = nil
        }
    }
    private func load(_ path: String) async throws {
        guard let store, sessions[path] == nil else { return }
        let loaded = try await store.load(path)
        let session = DocumentSession(path: path, loaded: loaded, store: store)
        sessions[path] = session
        // Run conflict recovery on first open as well as on later presenter
        // notifications. Resolved-but-not-removed versions left by older builds
        // may otherwise never generate a fresh iCloud change callback.
        await session.refresh()
        await session.save()
        if session.conflictPath != nil { entries = try await store.list() }
    }
    func close(_ path: String) async {
        navigationGeneration = UUID()
        await sessions[path]?.save()
        guard sessions[path]?.isDirty != true else { error = String(localized: "Документ ещё не сохранён."); return }
        tabs.removeAll { $0.path == path }
        if sourceNavigation?.path == path { sourceNavigation = nil }
        if activePath == path { activePath = tabs.first?.path }
        if secondaryPath == path { secondaryPath = nil }
        if chatPath != path { sessions[path] = nil }; persistTabs()
    }
    func saveAll() async { for session in sessions.values { await session.save() }; persistTabs() }
    func analyzeCanvasStorage(_ path: String) async throws -> CanvasStorageReport {
        guard let store else { throw StudyError.invalidPath }
        if let session = sessions[path] {
            await session.save()
            guard !session.isDirty, session.conflictPath == nil else { throw StudyError.modelUnavailable("Сначала сохраните документ и разрешите конфликт.") }
        }
        return try await store.analyzeCanvasStorage(path, keeping: sessions[path]?.protectedAssetNames ?? [])
    }
    func prepareCanvasCompaction(_ report: CanvasStorageReport) async throws -> PreparedCanvasCompaction {
        guard let store else { throw StudyError.invalidPath }
        let current = try await analyzeCanvasStorage(report.path)
        guard current.fingerprint == report.fingerprint else { throw StudyError.staleRevision }
        let backups = URL.applicationSupportDirectory.appendingPathComponent("Yohaku/CanvasBackups", isDirectory: true)
        return try await store.prepareCanvasCompaction(report, backupDirectory: backups)
    }
    func applyCanvasCompaction(_ prepared: PreparedCanvasCompaction) async throws {
        guard let store else { throw StudyError.invalidPath }
        let current = try await analyzeCanvasStorage(prepared.report.path)
        guard current.fingerprint == prepared.report.fingerprint else { throw StudyError.staleRevision }
        try await store.applyCanvasCompaction(prepared)
        await refresh()
    }
    func dropInactiveSessions() {
        sessions = sessions.filter { $0.key == activePath || $0.key == secondaryPath || $0.key == chatPath || $0.value.isDirty }
    }
    func create(_ name: String, kind: DocumentKind, folder: String = "") async {
        guard let store else { return }
        do {
            let path = (folder.isEmpty ? "" : folder + "/") + name + "." + kind.fileExtension
            try await store.create(path, kind: kind, text: kind == .markdown ? "# \(name)\n\n" : "")
            await refresh(); await open(path)
        } catch { self.error = error.localizedDescription }
    }
    func createFolder(_ path: String) async { do { try await store?.createFolder(path); await refresh() } catch { self.error = error.localizedDescription } }
    func move(_ path: String, to destination: String) async {
        await saveAll()
        guard !sessions.values.contains(where: \.isDirty) else { error = String(localized: "Сначала разрешите ошибки сохранения."); return }
        do {
            try await store?.move(path, to: destination)
            sourceNavigation = nil
            func mapped(_ old: String) -> String { old == path || old.hasPrefix(path + "/") ? destination + old.dropFirst(path.count) : old }
            var remapped: [String: DocumentSession] = [:]
            for (key, session) in sessions { let new = mapped(key); session.path = new; remapped[new] = session }
            sessions = remapped; tabs = tabs.map { var tab = $0; tab.path = mapped(tab.path); return tab }
            activePath = activePath.map(mapped); secondaryPath = secondaryPath.map(mapped); chatPath = chatPath.map(mapped)
            await refresh(); persistTabs()
        } catch { self.error = error.localizedDescription }
    }
    func trash(_ path: String) async {
        navigationGeneration = UUID()
        func isInsideDeletedItem(_ candidate: String) -> Bool {
            candidate == path || candidate.hasPrefix(path + "/")
        }

        // A damaged package may no longer have manifest.json, so trying to save it
        // before deletion makes the recovery action itself impossible. Preserve all
        // unrelated work, but deliberately discard unsaved state under the item the
        // user chose to delete.
        for (sessionPath, session) in sessions where !isInsideDeletedItem(sessionPath) { await session.save() }
        guard !sessions.contains(where: { !isInsideDeletedItem($0.key) && $0.value.isDirty }) else {
            error = String(localized: "Сначала сохраните документы.")
            return
        }

        let removedSessions = sessions.filter { isInsideDeletedItem($0.key) }
        for session in removedSessions.values { await session.suspendSavingForDeletion() }
        for sessionPath in removedSessions.keys { sessions[sessionPath] = nil }
        let previousChatPath = chatPath
        if let chatPath, isInsideDeletedItem(chatPath) { self.chatPath = nil }
        do {
            try await store?.trash(path)
            tabs.removeAll { isInsideDeletedItem($0.path) }
            if let activePath, isInsideDeletedItem(activePath) { self.activePath = tabs.first?.path }
            if let secondaryPath, isInsideDeletedItem(secondaryPath) { self.secondaryPath = nil }
            if let pendingContext, isInsideDeletedItem(pendingContext.path) { self.pendingContext = nil }
            if let request = sourceNavigation, isInsideDeletedItem(request.path) { sourceNavigation = nil }
            if let previousChatPath, isInsideDeletedItem(previousChatPath) { agent.cancel() }
            if activePath == nil { backlinks = [] }
            await refresh()
            persistTabs()
            error = nil
        } catch {
            for (sessionPath, session) in removedSessions { sessions[sessionPath] = session }
            chatPath = previousChatPath
            self.error = error.localizedDescription
        }
    }
    func ask(_ context: SourceContext) { pendingContext = context; chatPath = context.path; showAgent = true }
    func openLink(_ link: String, source: String) {
        if let resolved = NoteLinks.resolve(link, source: source) {
            if entries.contains(where: { $0.isDirectory && $0.path == resolved.path }) {
                query = resolved.path
                search()
                return
            }
            let fragment = resolved.fragment?.replacingOccurrences(of: "page=", with: "")
            Task { await open(resolved.path, pageID: fragment.flatMap(UUID.init(uuidString:))) }
        } else if let url = URL(string: link), ["https", "http"].contains(url.scheme) { UIApplication.shared.open(url) }
        else { error = String(localized: "Ссылка недоступна.") }
    }
    func accept(_ proposal: ChangeProposal) async {
        do {
            if let session = sessions[proposal.path] { try await session.accept(proposal) }
            else { _ = try await store?.apply(proposal) }
            agent.proposals.removeAll { $0.id == proposal.id }; await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func externalMove(_ old: URL, to new: URL) async {
        guard let root, old.path.hasPrefix(root.path + "/"), new.path.hasPrefix(root.path + "/") else {
            error = String(localized: "Хранилище перемещено или доступ к нему изменился. Выберите папку повторно."); return
        }
        let oldPath = String(old.path.dropFirst(root.path.count + 1)), newPath = String(new.path.dropFirst(root.path.count + 1))
        guard entries.contains(where: { $0.path == oldPath }) || sessions[oldPath] != nil else { return }
        do {
            try await store?.reconcileExternalMove(oldPath, to: newPath)
            sourceNavigation = nil
            func mapped(_ path: String) -> String { path == oldPath || path.hasPrefix(oldPath + "/") ? newPath + path.dropFirst(oldPath.count) : path }
            var updated: [String: DocumentSession] = [:]
            for (key, session) in sessions { session.path = mapped(key); updated[mapped(key)] = session }
            sessions = updated
            tabs = tabs.map { var tab = $0; tab.path = mapped(tab.path); return tab }
            activePath = activePath.map(mapped); secondaryPath = secondaryPath.map(mapped); chatPath = chatPath.map(mapped)
            persistTabs(); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func seed() async throws {
        guard let store else { return }
        try await store.createFolder("日本語")
        var notebook = try await store.create("日本語/Практика.studycanvas", kind: .notebook)
        notebook.content.pages[0].paper.pattern = .japanese; notebook.content.pages[0].paper.spacing = 42
        notebook.content.pages[0].objects = [.init(kind: .text, frame: Rect(x: 42, y: 42, width: 500, height: 108), content: "はじめましょう\nМесто для новых слов и маленьких открытий.")]
        try await store.save("日本語/Практика.studycanvas", content: notebook.content, expectedRevision: notebook.revision)
        try await store.create("日本語/Начало.md", kind: .markdown, text: """
        # Место для мысли

        **Yohaku · 余白** — свободное пространство на странице.

        Здесь можно писать, собирать знания и задавать вопросы.

        ## Сегодня

        - [ ] Открыть тетрадь и написать несколько иероглифов
        - [ ] Выделить фрагмент и спросить агента
        - [ ] Сохранить объяснение в заметку

        [Открыть тетрадь](Практика.studycanvas)

        > 少しずつ — понемногу, шаг за шагом.
        """
        )
        await refresh(); await open("日本語/Начало.md"); await open("日本語/Практика.studycanvas")
    }
}

private final class VaultPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let changed: @MainActor @Sendable () async -> Void
    let moved: @MainActor @Sendable (URL, URL) async -> Void
    init(url: URL, changed: @escaping @MainActor @Sendable () async -> Void, moved: @escaping @MainActor @Sendable (URL, URL) async -> Void) {
        presentedItemURL = url; self.changed = changed; self.moved = moved; super.init(); presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func presentedItemDidChange() { Task { await changed() } }
    func presentedSubitemDidChange(at url: URL) { Task { await changed() } }
    func presentedSubitemDidAppear(at url: URL) { Task { await changed() } }
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { Task { await moved(oldURL, newURL) } }
    func presentedItemDidMove(to newURL: URL) { if let presentedItemURL { Task { await moved(presentedItemURL, newURL) } } }
}
