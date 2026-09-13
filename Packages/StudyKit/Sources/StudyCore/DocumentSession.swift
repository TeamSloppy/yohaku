import Foundation
import Observation

@MainActor @Observable
public final class DocumentSession {
    public var path: String
    public private(set) var content: DocumentContent
    public private(set) var revision: String
    public private(set) var isDirty = false
    public private(set) var isSaving = false
    public var error: String?
    public var conflictPath: String?
    public let store: VaultStore
    private var assets: [String: Data] = [:]
    private var editVersion = 0
    private var pendingSave: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var undoHistory: [DocumentContent] = []
    private var redoHistory: [DocumentContent] = []
    private var editingGroup: DocumentContent?

    public init(path: String, loaded: LoadedDocument, store: VaultStore) {
        self.path = path; self.content = loaded.content; self.revision = loaded.revision; self.store = store
    }
    public func edit(_ mutation: (inout DocumentContent) -> Void) {
        let old = content
        mutation(&content)
        if editingGroup == nil && old.contentRevision != content.contentRevision { recordUndo(old) }
        scheduleSave()
    }
    private func scheduleSave() {
        editVersion += 1; isDirty = true
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            await self?.save()
        }
    }
    public func beginEditingGroup() { if editingGroup == nil { editingGroup = content } }
    public func endEditingGroup() {
        if let old = editingGroup, old.contentRevision != content.contentRevision { recordUndo(old) }
        editingGroup = nil
    }
    public func undo() {
        guard let old = undoHistory.popLast() else { return }
        redoHistory.append(content); restoreEditableContent(old)
    }
    public func redo() {
        guard let next = redoHistory.popLast() else { return }
        undoHistory.append(content); restoreEditableContent(next)
    }
    private func restoreEditableContent(_ snapshot: DocumentContent) {
        content.markdown = snapshot.markdown; content.pages = snapshot.pages; scheduleSave()
    }
    private func recordUndo(_ content: DocumentContent) {
        var compact = content; compact.messages = []
        undoHistory.append(compact); if undoHistory.count > 50 { undoHistory.removeFirst() }; redoHistory = []
    }
    public func addAsset(_ data: Data, extension suffix: String) -> String {
        let name = "assets/\(UUID().uuidString).\(suffix)"; assets[name] = data; return name
    }
    public func asset(_ name: String) async throws -> Data {
        if let data = assets[name] { return data }
        return try await store.readAsset(path, name: name)
    }
    public func save() async {
        pendingSave?.cancel(); pendingSave = nil
        if let saveTask { await saveTask.value; return }
        guard isDirty, conflictPath == nil else { return }
        let task = Task { [weak self] in await self?.performSave() }
        let wrapped = Task<Void, Never> { _ = await task.value }
        saveTask = wrapped; await wrapped.value; saveTask = nil
    }
    private func performSave() async {
        isSaving = true
        defer { isSaving = false }
        while isDirty && conflictPath == nil {
            let version = editVersion, snapshot = content, writingAssets = assets
            do {
                let saved = try await store.save(path, content: snapshot, expectedRevision: revision, assets: writingAssets)
                revision = saved.revision
                for key in writingAssets.keys { assets.removeValue(forKey: key) }
                isDirty = version != editVersion; error = nil
                if !isDirty {
                    var keep = Set(assets.keys)
                    let snapshots = [content] + undoHistory + redoHistory
                    for snapshot in snapshots {
                        for page in snapshot.pages {
                            if let file = page.drawingFile { keep.insert(file) }
                            for shard in page.shards { keep.insert(shard.file) }
                            for object in page.objects where object.kind == .image { keep.insert(object.content) }
                        }
                    }
                    // Failure to clean old assets must never discard a successfully saved document.
                    try? await store.pruneAssets(path, keeping: keep)
                }
            } catch StudyError.staleRevision {
                do { conflictPath = try await store.preserveConflict(path, content: snapshot, assets: writingAssets) }
                catch {
                    self.error = String.localizedStringWithFormat(
                        String(localized: "Не удалось сохранить копию конфликта: %@"),
                        error.localizedDescription
                    )
                    return
                }
                error = StudyError.staleRevision.localizedDescription
            } catch { self.error = error.localizedDescription; return }
        }
    }
    public func refresh() async {
        guard !isSaving, conflictPath == nil else { return }
        do {
            let cloudCopies = try await store.preserveCloudVersions(path)
            if let first = cloudCopies.first {
                if isDirty { conflictPath = try await store.preserveConflict(path, content: content, assets: assets) }
                else { conflictPath = first }
                error = String(localized: "Обнаружены версии iCloud. Все варианты сохранены отдельными файлами. Выберите версию."); return
            }
            let loaded = try await store.load(path)
            if loaded.revision != revision {
                if isDirty { await save() }
                else { content = loaded.content; revision = loaded.revision; undoHistory = []; redoHistory = [] }
            }
        } catch { self.error = error.localizedDescription }
    }
    public func useDiskVersion() async throws {
        let loaded = try await store.load(path)
        content = loaded.content; revision = loaded.revision; assets.removeAll()
        undoHistory = []; redoHistory = []
        isDirty = false; conflictPath = nil; error = nil
    }
    public func useConflictCopy() async throws {
        guard let conflictPath else { return }
        path = conflictPath; try await useDiskVersion()
    }
    public func accept(_ proposal: ChangeProposal) async throws {
        // A proposal must also match unsaved state, not merely the last persisted revision.
        await save()
        guard !isDirty, conflictPath == nil else { throw StudyError.staleRevision }
        let applied = try await store.apply(proposal)
        if proposal.path == path { recordUndo(content); content = applied.content; revision = applied.revision }
    }
}
