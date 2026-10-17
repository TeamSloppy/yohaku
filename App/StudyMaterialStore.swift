import Foundation
import Observation
import StudyCore

@MainActor @Observable final class StudyMaterialStore {
    private(set) var state = StudyMaterialState()
    private(set) var storageBlocked = true
    private(set) var canCancelIntent = false
    var error: String?
    var records: [StudyMaterialRecord] { state.records }
    var isBlocked: Bool { storageBlocked || !state.intents.isEmpty }
    private let writer: any StudyStateFileWriting
    private var url: URL?
    private var revision: String?
    private var epoch = UUID()
    private var tail: Task<Void, Never>?
    private var supersededIDs: Set<UUID> = []
    func markSuperseded(_ ids: Set<UUID>) { supersededIDs.formUnion(ids) }
    init(writer: any StudyStateFileWriting) { self.writer = writer }
    func close() { supersededIDs = []; epoch = UUID(); state = .init(); url = nil; revision = nil; storageBlocked = true; canCancelIntent = false; error = nil }

    private func serial<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail, request = epoch
        let task = Task { @MainActor in
            await previous?.value
            guard self.epoch == request else { throw StudyImportError.staleVault }
            return try await operation()
        }
        tail = Task { _ = try? await task.value }
        return try await task.value
    }
    private func commit(_ next: StudyMaterialState, request: UUID) async throws {
        guard epoch == request, let url else { throw StudyImportError.staleVault }
        let saved = try await writer.writeState(next, to: url, expectedRevision: revision)
        guard epoch == request else { throw StudyImportError.staleVault }
        state = next; revision = saved; error = nil
    }
    private func fail(_ failure: Error, request: UUID) {
        guard epoch == request else { return }
        if failure as? StudyImportError == .unavailable, isBlocked, error != nil { return }
        error = failure.localizedDescription
        if failure as? StudyFileError == .conflict || failure as? StudyImportError == .dependencyChanged { storageBlocked = true }
        canCancelIntent = failure as? StudyImportError == .ambiguous
    }
    private func writable() throws {
        guard !isBlocked, url != nil else { throw StudyImportError.unavailable }
    }
    func open(vaultRoot: URL, cards: FlashcardStore) async {
        close(); url = vaultRoot.appendingPathComponent(".workspace/study-state.json")
        await recover(cards: cards, acknowledgeConflicts: false)
    }
    func recover(cards: FlashcardStore, acknowledgeConflicts: Bool = true) async {
        let request = epoch
        do {
            try await serial { [self] in
                guard let url else { throw StudyImportError.unavailable }
                let loaded = try await (acknowledgeConflicts ? writer.recoverState(url) : writer.loadState(url))
                guard epoch == request else { throw StudyImportError.staleVault }
                state = loaded.state; revision = loaded.revision; storageBlocked = loaded.hasConflict; canCancelIntent = false
                guard !storageBlocked else { throw StudyFileError.conflict }
                for intent in state.intents {
                    try await cards.recoverMaterialImport(intent, dependency: .init(url: url, revision: revision!))
                    try await acknowledge(intent, request: request)
                }
                error = nil
            }
        } catch { fail(error, request: request) }
    }
    private func acknowledge(_ intent: StudyAcceptanceIntent, request: UUID) async throws {
        var next = state
        guard let index = next.records.firstIndex(where: { $0.id == intent.materialID }) else { throw StudyImportError.dependencyChanged }
        next.records[index].disposition = .accepted; next.records[index].cardID = intent.card.id
        next.intents.removeAll { $0.id == intent.id }
        try await commit(next, request: request)
    }
    func save(_ incoming: [StudyMaterialRecord], existingCards: [Flashcard] = [], ifCurrent: @escaping @MainActor () -> Bool) async throws -> [StudyMaterialRecord] {
        let request = epoch
        do {
            return try await serial { [self] in
                try writable(); guard ifCurrent() else { throw StudyError.staleRevision }
                var next = state, saved: [StudyMaterialRecord] = []
                let library = Set(existingCards.filter { $0.handwriting == nil }.map { StudyMaterialFields($0).fingerprint })
                for record in incoming {
                    if library.contains(record.fields.fingerprint) { continue }
                    if next.records.contains(where: { $0.fields.fingerprint == record.fields.fingerprint &&
                        ($0.disposition == .accepted || ($0.disposition == .rejected && $0.source.sameScope(as: record.source))) }) { continue }
                    var record = record
                    if let index = next.records.firstIndex(where: { $0.disposition == .pending && $0.fields.fingerprint == record.fields.fingerprint }) {
                        record.id = next.records[index].id; next.records[index] = record
                    } else { next.records.append(record) }
                    saved.removeAll { $0.id == record.id }; saved.append(record)
                }
                supersededIDs.subtract(saved.map(\.id))
                try await commit(next, request: request)
                var invalidated = state
                for index in invalidated.records.indices where supersededIDs.contains(invalidated.records[index].id) {
                    invalidated.records[index].sourceSuperseded = true; invalidated.records[index].freshness = .stale
                }
                if invalidated != state { try await commit(invalidated, request: request) }
                return saved
            }
        } catch { fail(error, request: request); throw error }
    }
    func accept(_ id: UUID, cards: FlashcardStore,
                validate: @escaping @MainActor (StudyMaterialSource) async throws -> Void) async -> Bool {
        let request = epoch
        do {
            try await serial { [self] in
                try writable()
                guard let record = state.records.first(where: { $0.id == id }), record.disposition == .pending,
                      record.freshness == .current, record.sourceSuperseded != true, !supersededIDs.contains(id) else { throw StudyError.staleRevision }
                let intent = try await cards.importMaterial(record) { [self] intent in
                    guard epoch == request else { throw StudyImportError.staleVault }
                    try await validate(record.source)
                    guard epoch == request else { throw StudyImportError.staleVault }
                    guard !supersededIDs.contains(id), state.records.first(where: { $0.id == id })?.disposition == .pending else { throw StudyError.staleRevision }
                    var next = state; next.intents.append(intent)
                    try await commit(next, request: request)
                    return StudyStateDependency(url: url!, revision: revision!)
                }
                try await acknowledge(intent, request: request)
            }
            return true
        } catch { fail(error, request: request); return false }
    }
    func reject(_ ids: Set<UUID>) async -> Bool { await change { state in
        for index in state.records.indices where ids.contains(state.records[index].id) && state.records[index].disposition == .pending {
            state.records[index].disposition = .rejected
        }
    } }
    func supersede(_ ids: Set<UUID>) async -> Bool { await change { state in
        for index in state.records.indices where ids.contains(state.records[index].id) && state.records[index].disposition == .pending {
            state.records[index].sourceSuperseded = true; state.records[index].freshness = .stale
        }
    } }
    func remap(_ old: String, to new: String) async -> Bool { await change { state in
        for index in state.records.indices {
            let path = state.records[index].source.path
            if path == old || path.hasPrefix(old + "/") { state.records[index].source.path = new + path.dropFirst(old.count) }
        }
    } }
    private func change(_ edit: @escaping @MainActor (inout StudyMaterialState) -> Void) async -> Bool {
        let request = epoch
        do {
            try await serial { [self] in
                try writable(); var next = state; edit(&next)
                if next != state { try await commit(next, request: request) }
            }
            return true
        } catch { fail(error, request: request); return false }
    }
    func refreshSources(_ check: @escaping @MainActor (StudyMaterialSource) async -> StudyMaterialRecord.Freshness) async {
        guard !isBlocked else { return }
        let request = epoch
        do {
            try await serial { [self] in
                try writable(); var next = state
                for index in next.records.indices {
                    let freshness = await check(next.records[index].source)
                    guard epoch == request else { throw StudyImportError.staleVault }
                    next.records[index].freshness = next.records[index].sourceSuperseded == true ? .stale : freshness
                }
                if next != state { try await commit(next, request: request) }
            }
        } catch { fail(error, request: request) }
    }
    func cancelPendingAcceptance() async -> Bool {
        let request = epoch
        do {
            try await serial { [self] in
                guard canCancelIntent, !storageBlocked else { throw StudyImportError.unavailable }
                var next = state; next.intents = []
                try await commit(next, request: request); canCancelIntent = false
            }
            return true
        } catch { fail(error, request: request); return false }
    }
}
