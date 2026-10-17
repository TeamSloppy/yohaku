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
}

/// Each coordinated accessor completes synchronously: no actor reentrancy between compare and replace.
actor StudyFileWriter: StudyFileWriting {
    private let fm = FileManager.default

    func load(_ url: URL) throws -> StudyFileSnapshot {
        try coordinated(url, writing: false) { url in
            let data = try read(url)
            return StudyFileSnapshot(cards: try decode(data), revision: digest(data),
                                     hasConflict: fm.fileExists(atPath: marker(url).path) || !cloudVersions(url).isEmpty)
        }
    }

    func write(_ cards: [Flashcard], to url: URL, expectedRevision: String?) throws -> String {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let candidate = try encoder.encode(cards)
        return try coordinated(url, writing: true) { url in
            if fm.fileExists(atPath: marker(url).path) { throw StudyFileError.conflict }
            let current = try read(url)
            guard digest(current) == expectedRevision, cloudVersions(url).isEmpty else {
                // Leave the authoritative external file untouched, including malformed bytes.
                if let current { try current.write(to: copyURL(url, kind: "external"), options: .atomic) }
                try candidate.write(to: marker(url), options: .atomic)
                throw StudyFileError.conflict
            }
            try candidate.write(to: url, options: .atomic)
            return digest(candidate)!
        }
    }

    func recover(_ url: URL) throws -> StudyFileSnapshot {
        try coordinated(url, writing: true) { url in
            let data = try read(url)
            let cards = try decode(data)
            let versions = cloudVersions(url)
            for version in versions {
                try coordinated(version.url, writing: false) { versionURL in
                    try fm.copyItem(at: versionURL, to: copyURL(url, kind: "cloud"))
                }
            }
            // Copies survive acknowledgement; removing the marker is the final recovery step.
            if fm.fileExists(atPath: marker(url).path) {
                try fm.moveItem(at: marker(url), to: copyURL(url, kind: "recovered"))
            }
            for version in versions { version.isResolved = true; try? version.remove() }
            return StudyFileSnapshot(cards: cards, revision: digest(data), hasConflict: false)
        }
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
        url.deletingLastPathComponent().appendingPathComponent("flashcards-conflict.json")
    }
    private func copyURL(_ url: URL, kind: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("flashcards-\(kind)-\(UUID().uuidString).json")
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
