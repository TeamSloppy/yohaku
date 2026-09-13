import Foundation
import Observation
import StudyIntelligence

@MainActor @Observable
final class NetworkModelSettingsState {
    var key = ""
    var status = ""
    var models: [NetworkModelOption] = []
    var connected = false
    var device: CodexAuthorization.DeviceCode?
    var signingIn = false
    private var signature: String?
    private var loginTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var loginID: UUID?
    private var catalogID: UUID?

    func configure(_ configuration: ModelConfiguration) {
        let next = configuration.provider.rawValue + configuration.credentialAccount
        guard signature != next else { return }
        cancel()
        signature = next
        key = APIKeyStore.read(account: configuration.credentialAccount)
        status = ""; models = []
        Task {
            let value = await CodexAuthorization.shared.isConnected()
            guard signature == next else { return }
            connected = value
            if configuration.provider == .codex, value { loadModels(configuration: configuration) }
        }
    }

    func saveKey(configuration: ModelConfiguration) {
        do {
            try APIKeyStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: configuration.credentialAccount)
            status = "Сохранено в Keychain."
        } catch { status = error.localizedDescription }
    }

    func loadModels(configuration: ModelConfiguration) {
        catalogTask?.cancel()
        let id = UUID(); catalogID = id
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        status = "Загрузка моделей…"
        catalogTask = Task {
            do {
                let result = configuration.provider == .codex
                    ? try await CodexAuthorization.shared.models()
                    : try await NetworkProviders.sloppyModels(endpoint: configuration.sloppyEndpoint, token: token)
                try Task.checkCancellation()
                guard catalogID == id else { return }
                models = result
                status = result.isEmpty ? "Каталог пуст. Можно указать Model ID вручную." : "Загружено моделей: \(result.count)."
            } catch is CancellationError { }
            catch { if catalogID == id { models = []; status = error.localizedDescription } }
        }
    }

    func startLogin(openURL: @escaping (URL) -> Void) {
        cancelLogin()
        let id = UUID(); loginID = id
        signingIn = true; status = "Получение device code…"
        loginTask = Task {
            defer { if loginID == id { signingIn = false } }
            do {
                let code = try await CodexAuthorization.shared.start()
                try Task.checkCancellation()
                guard loginID == id else { return }
                device = code; openURL(code.url)
                status = "Введите код в окне Codex."
                var interval = code.interval
                let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
                while Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    let result = try await CodexAuthorization.shared.poll(code)
                    try Task.checkCancellation()
                    guard loginID == id else { return }
                    switch result {
                    case .pending: break
                    case .slowDown: interval += 5
                    case .connected:
                        connected = true; device = nil; status = "Codex подключён."
                        var config = ModelConfiguration(); config.provider = .codex
                        loadModels(configuration: config)
                        return
                    }
                }
                device = nil; status = "Код истёк. Начните вход заново."
            } catch is CancellationError { }
            catch { if loginID == id { status = error.localizedDescription } }
        }
    }

    func disconnect() {
        cancel()
        Task {
            do { try await CodexAuthorization.shared.disconnect(); connected = false; models = []; status = "Codex отключён." }
            catch { status = error.localizedDescription }
        }
    }
    func cancelLogin() {
        loginID = nil; loginTask?.cancel(); loginTask = nil
        signingIn = false; device = nil
        status = "Вход отменён."
    }
    func cancel() {
        cancelLogin()
        catalogID = nil; catalogTask?.cancel(); catalogTask = nil
    }
}
