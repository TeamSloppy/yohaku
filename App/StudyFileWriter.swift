import CryptoKit
import Foundation

struct StudyFileSnapshot: Sendable {
    var cards: [Flashcard]
    var revision: String?
    var hasConflict: Bool
}

enum StudyFileError: Error, LocalizedError, Equatable {
    case conflict
    var errorDescription: String? {
        "Карточки изменены вне приложения. Обе версии сохранены. Загрузите сохранённую версию перед продолжением."
    }
}

protocol StudyFileWriting: Sendable {
    func load(_ url: URL) async throws -> StudyFileSnapshot
    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) async throws -> String
    func recover(_ url: URL) async throws -> StudyFileSnapshot
    func writeImportedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: StudyAcceptanceIntent, dependency: StudyStateDependency) async throws -> String
    func writeReviewedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: DailyLessonReviewIntent, dependency: StudyStateDependency) async throws -> String
    func verifyLessonCards(_ cards: [Flashcard], at url: URL, expectedRevision: String?, dependency: StudyStateDependency) async throws
}
extension StudyFileWriting {
    func verifyLessonCards(_ cards: [Flashcard], at url: URL, expectedRevision: String?, dependency: StudyStateDependency) async throws {
        throw StudyImportError.unavailable
    }
    func writeReviewedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: DailyLessonReviewIntent, dependency: StudyStateDependency) async throws -> String {
        throw StudyImportError.unavailable
    }
    func writeImportedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: StudyAcceptanceIntent, dependency: StudyStateDependency) async throws -> String {
        throw StudyImportError.unavailable // Older adapters must never bypass the dependency guard.
    }
}
protocol StudyStateFileWriting: Sendable {
    func loadState(_ url: URL) async throws -> StudyStateSnapshot
    func writeState(_ state: StudyMaterialState, to url: URL, expectedRevision: String?) async throws -> String
    func recoverState(_ url: URL) async throws -> StudyStateSnapshot
}

/// Each coordinated accessor completes synchronously: no actor reentrancy between compare and replace.
actor StudyFileWriter: StudyFileWriting, StudyStateFileWriting {
    private let fm = FileManager.default

    func load(_ url: URL) throws -> StudyFileSnapshot {
        try coordinated(url, writing: false) { url in
            let data = try read(url)
            return StudyFileSnapshot(cards: try decode(data), revision: digest(data), hasConflict: conflicted(url))
        }
    }

    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) throws -> String {
        let candidate = try Self.encode(cards)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try coordinated(url, writing: true) { try replace(candidate, at: $0, expectedRevision: expectedRevision) }
    }

    func recover(_ url: URL) throws -> StudyFileSnapshot {
        try coordinated(url, writing: true) { url in
            let data = try read(url), cards = try decode(data)
            try recoverConflicts(url)
            return StudyFileSnapshot(cards: cards, revision: digest(data), hasConflict: false)
        }
    }

    func loadState(_ url: URL) throws -> StudyStateSnapshot {
        try coordinated(url, writing: false) { url in
            let data = try read(url)
            return StudyStateSnapshot(state: try StudyMaterialState.decode(data), revision: digest(data), hasConflict: conflicted(url))
        }
    }
    func writeState(_ state: StudyMaterialState, to url: URL, expectedRevision: String?) throws -> String {
        let candidate = try Self.encode(state)
        _ = try StudyMaterialState.decode(candidate)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try coordinated(url, writing: true) { url in
            let current = try read(url)
            if digest(current) == expectedRevision { _ = try StudyMaterialState.decode(current) }
            return try replace(candidate, at: url, expectedRevision: expectedRevision)
        }
    }
    func recoverState(_ url: URL) throws -> StudyStateSnapshot {
        try coordinated(url, writing: true) { url in
            let data = try read(url), state = try StudyMaterialState.decode(data)
            try recoverConflicts(url)
            return StudyStateSnapshot(state: state, revision: digest(data), hasConflict: false)
        }
    }

    func writeImportedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: StudyAcceptanceIntent, dependency: StudyStateDependency) throws -> String {
        guard dependency.url.standardizedFileURL == url.deletingLastPathComponent().appendingPathComponent("study-state.json").standardizedFileURL else {
            throw StudyImportError.dependencyChanged
        }
        let candidate = try Self.encode(cards)
        var failure: NSError?, result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: dependency.url, options: [], writingItemAt: url, options: .forReplacing, error: &failure) { stateURL, cardURL in
            result = Result {
                guard let data = try read(stateURL) else { throw StudyImportError.dependencyChanged }
                let state = try StudyMaterialState.decode(data)
                guard digest(data) == dependency.revision, !conflicted(stateURL), state.intents.contains(intent) else {
                    throw StudyImportError.dependencyChanged
                }
                return try replace(candidate, at: cardURL, expectedRevision: expectedRevision)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    func writeReviewedCards(_ cards: [Flashcard], to url: URL, expectedRevision: String?,
                            intent: DailyLessonReviewIntent, dependency: StudyStateDependency) throws -> String {
        guard dependency.url.standardizedFileURL == url.deletingLastPathComponent().appendingPathComponent("study-state.json").standardizedFileURL else {
            throw StudyImportError.dependencyChanged
        }
        let candidate = try Self.encode(cards)
        var failure: NSError?, result: Result<String, Error>?
        NSFileCoordinator().coordinate(readingItemAt: dependency.url, options: [], writingItemAt: url, options: .forReplacing, error: &failure) { stateURL, cardURL in
            result = Result {
                guard let data = try read(stateURL) else { throw StudyImportError.dependencyChanged }
                let state = try StudyMaterialState.decode(data)
                guard digest(data) == dependency.revision, !conflicted(stateURL), state.lessonIntent == intent else {
                    throw StudyImportError.dependencyChanged
                }
                return try replace(candidate, at: cardURL, expectedRevision: expectedRevision)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        return try result.get()
    }

    /// A checkpoint can depend on card absence/content without writing a card candidate.
    func verifyLessonCards(_ cards: [Flashcard], at url: URL, expectedRevision: String?, dependency: StudyStateDependency) throws {
        guard dependency.url.standardizedFileURL == url.deletingLastPathComponent().appendingPathComponent("study-state.json").standardizedFileURL else {
            throw StudyImportError.dependencyChanged
        }
        let candidate = try Self.encode(cards)
        var failure: NSError?, result: Result<Void, Error>?
        NSFileCoordinator().coordinate(readingItemAt: dependency.url, options: [], writingItemAt: url, options: .forReplacing, error: &failure) { stateURL, cardURL in
            result = Result {
                guard let data = try read(stateURL) else { throw StudyImportError.dependencyChanged }
                _ = try StudyMaterialState.decode(data)
                guard digest(data) == dependency.revision, !conflicted(stateURL) else { throw StudyImportError.dependencyChanged }
                try verify(candidate, at: cardURL, expectedRevision: expectedRevision)
            }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        try result.get()
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    private func conflicted(_ url: URL) -> Bool {
        fm.fileExists(atPath: marker(url).path) || !cloudVersions(url).isEmpty
    }
    private func replace(_ candidate: Data, at url: URL, expectedRevision: String?) throws -> String {
        try verify(candidate, at: url, expectedRevision: expectedRevision)
        try candidate.write(to: url, options: .atomic)
        return digest(candidate)!
    }
    private func verify(_ candidate: Data, at url: URL, expectedRevision: String?) throws {
        if fm.fileExists(atPath: marker(url).path) { throw StudyFileError.conflict }
        let current = try read(url)
        guard digest(current) == expectedRevision, cloudVersions(url).isEmpty else {
            if let current { try current.write(to: copyURL(url, kind: "external"), options: .atomic) }
            try candidate.write(to: marker(url), options: .atomic)
            throw StudyFileError.conflict
        }
    }
    private func recoverConflicts(_ url: URL) throws {
        let versions = cloudVersions(url)
        for version in versions {
            try coordinated(version.url, writing: false) { try fm.copyItem(at: $0, to: copyURL(url, kind: "cloud")) }
        }
        if fm.fileExists(atPath: marker(url).path) { try fm.moveItem(at: marker(url), to: copyURL(url, kind: "recovered")) }
        for version in versions { version.isResolved = true; try? version.remove() }
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            // An iCloud placeholder is not an empty library.
            if (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true { throw error }
            return nil
        }
    }
    private func decode(_ data: Data?) throws -> [Flashcard] {
        try data.map { try JSONDecoder().decode([Flashcard].self, from: $0) } ?? []
    }
    private func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
    private func marker(_ url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-conflict.json")
    }
    private func copyURL(_ url: URL, kind: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(kind)-\(UUID().uuidString).json")
    }
    private func cloudVersions(_ url: URL) -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }
    private func coordinated<T>(_ url: URL, writing: Bool, _ body: (URL) throws -> T) throws -> T {
        var coordinationError: NSError?
        var result: Result<T, Error>?
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
                result = Result { try body(coordinatedURL) }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }
}


extension StudyFileWriter {
    func loadLearning(_ url: URL, recover: Bool) throws -> LearningSnapshot {
        try coordinated(url, writing: recover) { url in
            let data = try read(url), state = try LearningState.decode(data)
            if recover { try recoverConflicts(url) }
            return .init(state: state, revision: digest(data), conflicted: conflicted(url))
        }
    }
    func writeLearning(_ state: LearningState, to url: URL, expectedRevision: String?) throws -> String {
        try state.validate()
        let data = try Self.encode(state)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try coordinated(url, writing: true) { try replace(data, at: $0, expectedRevision: expectedRevision) }
    }
}
