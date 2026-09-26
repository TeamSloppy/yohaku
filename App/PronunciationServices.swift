import Foundation
import Observation
import StudyIntelligence

enum PronunciationProvider: String, CaseIterable, Hashable, Sendable {
    case kanjiAlive
    case forvo

    var title: String {
        switch self {
        case .kanjiAlive: "Kanji alive"
        case .forvo: "Forvo"
        }
    }
}

@MainActor @Observable
final class PronunciationServiceSettings {
    static let forvoAccount = "pronunciation-forvo-key"
    private static let providerPreference = "pronunciation-provider"
    static var currentProvider: PronunciationProvider {
        UserDefaults.standard.string(forKey: providerPreference)
            .flatMap(PronunciationProvider.init(rawValue:)) ?? .kanjiAlive
    }

    var provider: PronunciationProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerPreference) }
    }

    var forvoKey = ""
    var status = ""

    init() {
        provider = Self.currentProvider
        forvoKey = APIKeyStore.read(account: Self.forvoAccount)
    }

    func save() {
        do {
            try APIKeyStore.save(forvoKey.trimmed, account: Self.forvoAccount)
            status = "Сохранено в Keychain."
        } catch {
            status = error.localizedDescription
        }
    }

    static var storedForvoKey: String { APIKeyStore.read(account: forvoAccount) }
}

struct KanjiAlivePronunciation: Equatable, Sendable {
    var term: String
    var reading: String
    var audioURL: URL
}

enum KanjiAliveAudioCatalog {
    static let csvURL = URL(string: "https://raw.githubusercontent.com/kanjialive/kanji-data-media/master/language-data/ka_data.csv")!
    static let audioBaseURL = URL(string: "https://spectraldragon.github.io/yohaku/kanji-audio/")!

    private struct Row {
        var prefix: String
        var id: Int
        var examples: [(term: String, reading: String)]
    }

    private actor Catalog {
        static let shared = Catalog()
        private var rows: [Row]?

        func sample(for term: String, session: URLSession) async throws -> KanjiAlivePronunciation {
            if rows == nil {
                let (data, response) = try await session.data(from: KanjiAliveAudioCatalog.csvURL)
                try validate(response)
                rows = try parse(data)
            }
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            for row in rows ?? [] {
                guard let index = row.examples.firstIndex(where: { $0.term.precomposedStringWithCanonicalMapping == normalized }),
                      index < 12,
                      let letter = UnicodeScalar(97 + index).map(String.init) else { continue }
                let file = "\(row.prefix)_\(String(format: "%02d", row.id))_\(letter).mp3"
                guard let encodedFile = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                      let url = URL(string: encodedFile, relativeTo: KanjiAliveAudioCatalog.audioBaseURL)?.absoluteURL else {
                    throw PronunciationServiceError.invalidConfiguration
                }
                let example = row.examples[index]
                return KanjiAlivePronunciation(term: example.term, reading: example.reading, audioURL: url)
            }
            throw PronunciationServiceError.noKanjiAlivePronunciation
        }
    }

    static func fetchBest(term: String, session: URLSession = .shared) async throws -> KanjiAlivePronunciation {
        try await Catalog.shared.sample(for: term, session: session)
    }

    static func download(_ pronunciation: KanjiAlivePronunciation, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(from: pronunciation.audioURL)
        try validate(response)
        return data
    }

    private static func parse(_ data: Data) throws -> [Row] {
        guard let text = String(data: data, encoding: .utf8) else { throw PronunciationServiceError.invalidCatalog }
        let records = csvRecords(text)
        guard records.first?.first == "kanji" else { throw PronunciationServiceError.invalidCatalog }
        return try records.dropFirst().enumerated().compactMap { offset, cells in
            guard cells.count > 9, !cells[1].isEmpty else { return nil }
            guard let examplesData = cells[9].data(using: .utf8),
                  let rawExamples = try? JSONDecoder().decode([[String]].self, from: examplesData) else {
                throw PronunciationServiceError.invalidCatalog
            }
            let examples = rawExamples.compactMap { values -> (term: String, reading: String)? in
                guard let value = values.first,
                      let open = value.firstIndex(of: "（"),
                      let close = value[open...].firstIndex(of: "）") else { return nil }
                let term = String(value[..<open])
                let reading = String(value[value.index(after: open)..<close])
                guard !term.isEmpty, !reading.isEmpty else { return nil }
                return (term, reading)
            }
            return Row(prefix: cells[1], id: offset + 1, examples: examples)
        }
    }

    private static func csvRecords(_ text: String) -> [[String]] {
        let characters = Array(text)
        var records: [[String]] = []
        var cells: [String] = []
        var cell = ""
        var quoted = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" {
                    cell.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if character == "," && !quoted {
                cells.append(cell)
                cell = ""
            } else if character == "\n" && !quoted {
                cells.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
                if !cells.isEmpty { records.append(cells) }
                cells = []
                cell = ""
            } else if character != "\r" || quoted {
                cell.append(character)
            }
            index += 1
        }
        if !cell.isEmpty || !cells.isEmpty {
            cells.append(cell.trimmingCharacters(in: .whitespacesAndNewlines))
            records.append(cells)
        }
        return records
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PronunciationServiceError.serviceUnavailable
        }
    }
}

struct ForvoPronunciation: Equatable, Sendable {
    var audioURL: URL
    var username: String
    var country: String?
}

enum ForvoAPI {
    private struct Response: Decodable {
        struct Item: Decodable {
            var pathmp3: URL
            var username: String
            var country: String?
        }
        var items: [Item]
    }

    static func fetchBest(
        term: String,
        key: String,
        session: URLSession = .shared
    ) async throws -> ForvoPronunciation {
        guard !key.trimmed.isEmpty else { throw PronunciationServiceError.missingForvoKey }
        guard let requestURL = requestURL(term: term, key: key) else { throw PronunciationServiceError.invalidConfiguration }
        let (data, response) = try await session.data(from: requestURL)
        try validate(response)
        guard let item = try JSONDecoder().decode(Response.self, from: data).items.first else {
            throw PronunciationServiceError.noPronunciation
        }
        return ForvoPronunciation(audioURL: item.pathmp3, username: item.username, country: item.country)
    }

    static func download(_ pronunciation: ForvoPronunciation, session: URLSession = .shared) async throws -> Data {
        let (data, response) = try await session.data(from: pronunciation.audioURL)
        try validate(response)
        return data
    }

    static func requestURL(term: String, key: String) -> URL? {
        let components = [
            "key", key, "format", "json", "action", "word-pronunciations",
            "word", term, "language", "ja", "order", "rate-desc", "limit", "1"
        ].map(encodePathComponent)
        return URL(string: "https://apifree.forvo.com/" + components.joined(separator: "/"))
    }

    private static func encodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PronunciationServiceError.serviceUnavailable
        }
    }
}

enum PronunciationServiceError: LocalizedError {
    case missingForvoKey
    case invalidConfiguration
    case noPronunciation
    case noKanjiAlivePronunciation
    case invalidCatalog
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .missingForvoKey: "Добавьте API-ключ Forvo в настройках."
        case .invalidConfiguration: "Проверьте настройки сервиса произношения."
        case .noPronunciation: "Forvo не нашёл японскую запись для этой карточки."
        case .noKanjiAlivePronunciation: "Для этого слова нет аудиопримера Kanji alive. Выберите Forvo в настройках произношения."
        case .invalidCatalog: "Не удалось прочитать каталог произношения Kanji alive."
        case .serviceUnavailable: "Сервис произношения вернул ошибку. Попробуйте позже."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
