import Foundation
import Observation
import StudyIntelligence

@MainActor @Observable
final class PronunciationServiceSettings {
    static let forvoAccount = "pronunciation-forvo-key"

    var forvoKey = ""
    var status = ""

    init() {
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
    case serviceUnavailable

    var errorDescription: String? {
        switch self {
        case .missingForvoKey: "Добавьте API-ключ Forvo в настройках."
        case .invalidConfiguration: "Проверьте настройки сервиса произношения."
        case .noPronunciation: "Forvo не нашёл японскую запись для этой карточки."
        case .serviceUnavailable: "Сервис произношения вернул ошибку. Попробуйте позже."
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
