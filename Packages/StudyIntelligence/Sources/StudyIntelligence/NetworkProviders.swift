import AnyLanguageModel
import Foundation

public enum NetworkProviders {
    public static func sloppyModels(endpoint: String, token: String, session: URLSession = .shared) async throws -> [NetworkModelOption] {
        var request = URLRequest(url: try SloppyRemoteEndpoint.url(base: endpoint, path: "providers/models"))
        request.timeoutInterval = 30
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else { throw SloppyRemoteError.http(response.statusCode) }
        return try JSONDecoder().decode([NetworkModelOption].self, from: data).filter { !$0.id.hasPrefix("sloppy:") }
    }

    static func model(for config: ModelConfiguration) throws -> any LanguageModel {
        switch config.provider {
        case .codex:
            guard !config.codexModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelConnectionError.message("Выберите модель Codex в настройках.") }
            return NetworkLanguageModel(baseURL: "", accessToken: "", model: config.codexModel, codex: .shared)
        case .sloppy:
            guard !config.sloppyModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ModelConnectionError.message("Выберите модель сервера Sloppy в настройках.") }
            _ = try SloppyRemoteEndpoint.url(base: config.sloppyEndpoint, path: "providers/inference")
            return NetworkLanguageModel(baseURL: config.sloppyEndpoint, accessToken: APIKeyStore.read(account: config.credentialAccount), model: config.sloppyModel)
        case .network:
            guard let url = URL(string: config.endpoint), ["https", "http"].contains(url.scheme), url.host != nil,
                  url.user == nil, url.password == nil, !config.remoteID.isEmpty else { throw ModelConnectionError.message("Укажите endpoint и model ID в настройках.") }
            return OpenAILanguageModel(baseURL: url, apiKey: APIKeyStore.read(account: config.credentialAccount), model: config.remoteID)
        case .local: throw ModelConnectionError.message("Локальная модель не является сетевым провайдером.")
        }
    }

    static func migrateLegacyKey(configuration: ModelConfiguration) throws {
        let legacy = APIKeyStore.read()
        guard !legacy.isEmpty else { return }
        var network = configuration
        network.provider = .network
        if APIKeyStore.read(account: network.credentialAccount).isEmpty {
            try APIKeyStore.save(legacy, account: network.credentialAccount)
        }
        try APIKeyStore.save("")
    }
}
