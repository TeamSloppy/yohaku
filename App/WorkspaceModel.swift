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
    var chatPath: String?
    var showSettings = false
    var showFolderPicker = false
    var isUsingICloud = false
    var query = ""
    var searchResults: [VaultEntry] = []
    var backlinks: [VaultEntry] = []
    let agent = AgentSession()
    let flashcards = FlashcardStore()
    private var accessURL: URL?
    private var presenter: VaultPresenter?
    private var starting = false
    private var searchTask: Task<Void, Never>?
    private var refreshing = false
    private var vaultID: String?
    private var defaultsKey: String { "workspace-tabs-" + (vaultID ?? root?.path ?? "") }

    func start() async {
        guard !starting, store == nil else { return }; starting = true
        defer { starting = false }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            do {
                try await openVault(URL.temporaryDirectory.appendingPathComponent("UITest-\(UUID())"), remember: false)
                try await seed()
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
        agent.cancel(); await saveAll()
        guard !sessions.values.contains(where: { $0.isDirty }) else { throw StudyError.modelUnavailable("Сначала сохраните изменения или разрешите конфликт в текущем хранилище.") }
        if let presenter { NSFileCoordinator.removeFilePresenter(presenter) }
        accessURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { accessURL = url } else { accessURL = nil }
        let store = VaultStore(root: url); try await store.prepare()
        self.store = store; root = url; vaultID = try await store.identifier(); sessions = [:]; activePath = nil; secondaryPath = nil
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
        if let data = UserDefaults.standard.data(forKey: defaultsKey), let saved = try? JSONDecoder().decode(SavedTabs.self, from: data) {
            tabs = saved.tabs.filter { tab in entries.contains { $0.path == tab.path } }
            for tab in tabs { try await load(tab.path) }
            activePath = tabs.contains(where: { $0.path == saved.active }) ? saved.active : tabs.first?.path
            secondaryPath = tabs.contains(where: { $0.path == saved.secondary }) ? saved.secondary : nil
        } else { tabs = [] }
        let presenter = VaultPresenter(url: url, changed: { [weak self] in await self?.refresh() }, moved: { [weak self] old, new in await self?.externalMove(old, to: new) })
        self.presenter = presenter; NSFileCoordinator.addFilePresenter(presenter)
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
            for session in sessions.values { await session.refresh() }
            if let path = activePath { backlinks = try await store.backlinks(to: path) }
        } catch { self.error = error.localizedDescription }
    }
    func search() {
        searchTask?.cancel(); let query = query
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(200)); searchResults = try await store?.search(query) ?? [] }
            catch is CancellationError {} catch { self.error = error.localizedDescription }
        }
    }
    func open(_ path: String, secondary: Bool = false, pageID: UUID? = nil) async {
        do {
            if !secondary, let activePath, activePath != path {
                await sessions[activePath]?.save()
            }
            try await load(path)
            if !tabs.contains(where: { $0.path == path }) { tabs.append(DocumentTab(path: path, pageID: pageID)) }
            else if let pageID, let i = tabs.firstIndex(where: { $0.path == path }) { tabs[i].pageID = pageID }
            if secondary { secondaryPath = path } else { activePath = path }
            backlinks = try await store?.backlinks(to: path) ?? []; persistTabs()
        } catch { self.error = error.localizedDescription }
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
        await sessions[path]?.save()
        guard sessions[path]?.isDirty != true else { error = String(localized: "Документ ещё не сохранён."); return }
        tabs.removeAll { $0.path == path }
        if activePath == path { activePath = tabs.first?.path }
        if secondaryPath == path { secondaryPath = nil }
        if chatPath != path { sessions[path] = nil }; persistTabs()
    }
    func saveAll() async { for session in sessions.values { await session.save() }; persistTabs() }
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
            func mapped(_ old: String) -> String { old == path || old.hasPrefix(path + "/") ? destination + old.dropFirst(path.count) : old }
            var remapped: [String: DocumentSession] = [:]
            for (key, session) in sessions { let new = mapped(key); session.path = new; remapped[new] = session }
            sessions = remapped; tabs = tabs.map { var tab = $0; tab.path = mapped(tab.path); return tab }
            activePath = activePath.map(mapped); secondaryPath = secondaryPath.map(mapped); chatPath = chatPath.map(mapped)
            await refresh(); persistTabs()
        } catch { self.error = error.localizedDescription }
    }
    func trash(_ path: String) async {
        await saveAll()
        guard !sessions.values.contains(where: \.isDirty) else { error = String(localized: "Сначала сохраните документы."); return }
        do {
            try await store?.trash(path)
            for tab in tabs where tab.path == path || tab.path.hasPrefix(path + "/") { await close(tab.path) }
            await refresh()
        } catch { self.error = error.localizedDescription }
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
    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) { Task { await moved(oldURL, newURL) } }
    func presentedItemDidMove(to newURL: URL) { if let presentedItemURL { Task { await moved(presentedItemURL, newURL) } } }
}
