import Foundation

/// A read-only projection: the widget never opens or modifies the user's vault.
struct StudyWidgetCard: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var japanese: String
    var reading: String
    var translation: String
    var japaneseImage: Data?
    var readingImage: Data?
    var translationImage: Data?
}

struct StudyWidgetSnapshot: Codable, Equatable, Sendable {
    var cards: [StudyWidgetCard] = []

    func card(at date: Date) -> StudyWidgetCard? {
        guard !cards.isEmpty else { return nil }
        let hour = Int(floor(date.timeIntervalSince1970 / 3600))
        return cards[((hour % cards.count) + cards.count) % cards.count]
    }

    static func entryDates(from now: Date, calendar: Calendar = .current) -> [Date] {
        let hour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        return [now] + (1...48).map { hour.addingTimeInterval(Double($0) * 3600) }
    }
}

enum StudyWidgetStorage {
    static let groupID = "group.team.sloppy.yohaku"
    static let kind = "YohakuWords"
    static let studyURL = URL(string: "yohaku://study")!

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent("study-widget.json")
    }

    static func load(from url: URL? = fileURL) -> StudyWidgetSnapshot {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(StudyWidgetSnapshot.self, from: data) else {
            return StudyWidgetSnapshot()
        }
        return snapshot
    }

    static func save(_ snapshot: StudyWidgetSnapshot, to url: URL? = fileURL) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
