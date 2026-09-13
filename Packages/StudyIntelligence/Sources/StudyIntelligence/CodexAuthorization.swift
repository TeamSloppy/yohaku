import Foundation

public struct NetworkModelOption: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
}

public enum ModelConnectionError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

public actor CodexAuthorization {
    public static let shared = CodexAuthorization()
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public struct DeviceCode: Sendable {
        public let id: String
        public let code: String
        public let interval: Int
        public let expiresIn: Int
        public var url: URL { URL(string: "https://auth.openai.com/codex/device")! }
    }
    public enum PollResult: Sendable { case pending, slowDown, connected }
    struct Credentials: Codable, Sendable {
        var accessToken: String
        var refreshToken: String?
        var accountID: String?
        var expiresAt: Date
    }
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let read: @Sendable () -> String
    private let save: @Sendable (String) throws -> Void
    private var refreshTask: Task<Credentials, Error>?
    private var generation = 0

    public init() {
        transport = { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, response)
        }
        read = { APIKeyStore.read(account: "codex-oauth") }
        save = { try APIKeyStore.save($0, account: "codex-oauth") }
    }
    init(transport: @escaping Transport, read: @escaping @Sendable () -> String, save: @escaping @Sendable (String) throws -> Void) {
        self.transport = transport; self.read = read; self.save = save
    }
    public func isConnected() -> Bool { stored() != nil }
    public func disconnect() throws {
        generation += 1
        refreshTask?.cancel(); refreshTask = nil
        try save("")
    }
    public func start() async throws -> DeviceCode {
        let data = try await post("https://auth.openai.com/api/accounts/deviceauth/usercode", body: ["client_id": Self.clientID])
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let id = object?["device_auth_id"] as? String, let code = object?["user_code"] as? String else { throw URLError(.cannotParseResponse) }
        func number(_ key: String, fallback: Int) -> Int {
            (object?[key] as? Int) ?? Int(object?[key] as? String ?? "") ?? fallback
        }
        return DeviceCode(id: id, code: code, interval: max(1, number("interval", fallback: 5)), expiresIn: max(1, number("expires_in", fallback: 600)))
    }
    public func poll(_ device: DeviceCode) async throws -> PollResult {
        let revision = generation
        let request = try Self.request("https://auth.openai.com/api/accounts/deviceauth/token", body: ["device_auth_id": device.id, "user_code": device.code])
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        if [403, 404].contains(response.statusCode) { return .pending }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if object?["error"] as? String == "authorization_pending" { return .pending }
        if object?["error"] as? String == "slow_down" { return .slowDown }
        try Self.check(response)
        guard let code = object?["authorization_code"] as? String, let verifier = object?["code_verifier"] as? String else { throw URLError(.cannotParseResponse) }
        let credentials = try await exchange([
            "grant_type": "authorization_code", "code": code, "code_verifier": verifier,
            "redirect_uri": "https://auth.openai.com/deviceauth/callback", "client_id": Self.clientID,
        ])
        try Task.checkCancellation()
        guard revision == generation else { throw CancellationError() }
        try persist(credentials)
        return .connected
    }
    func credentials(forceRefresh: Bool = false) async throws -> Credentials {
        guard let current = stored() else { throw ModelConnectionError.message("Войдите в Codex в настройках моделей.") }
        if !forceRefresh, current.expiresAt.timeIntervalSinceNow > 60 { return current }
        if let refreshTask { return try await refreshTask.value }
        guard let token = current.refreshToken else { throw ModelConnectionError.message("Сессия Codex истекла. Войдите заново.") }
        let revision = generation
        let task = Task { try await self.exchange([
            "grant_type": "refresh_token", "refresh_token": token, "client_id": Self.clientID,
        ], previous: current) }
        refreshTask = task
        defer { if generation == revision { refreshTask = nil } }
        let renewed = try await task.value
        guard generation == revision else { throw CancellationError() }
        try persist(renewed)
        return renewed
    }
    public func models() async throws -> [NetworkModelOption] {
        let auth = try await credentials()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/models?client_version=0.128.0")!)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        if let id = auth.accountID { request.setValue(id, forHTTPHeaderField: "ChatGPT-Account-ID") }
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        try Self.check(response)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = root?["models"] as? [[String: Any]] ?? root?["data"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["slug"] as? String ?? row["id"] as? String else { return nil }
            return NetworkModelOption(id: id, title: row["display_name"] as? String ?? id)
        }
    }
    private func stored() -> Credentials? { try? JSONDecoder().decode(Credentials.self, from: Data(read().utf8)) }
    private func persist(_ value: Credentials) throws { try save(String(decoding: JSONEncoder().encode(value), as: UTF8.self)) }
    private func post(_ url: String, body: [String: String]) async throws -> Data {
        let (data, response) = try await transport(Self.request(url, body: body))
        try Self.check(response)
        return data
    }
    private func exchange(_ values: [String: String], previous: Credentials? = nil) async throws -> Credentials {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, response) = try await transport(request)
        try Self.check(response)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let token = object?["access_token"] as? String, !token.isEmpty else { throw URLError(.cannotParseResponse) }
        let claims = Self.claims(token)
        let auth = claims?["https://api.openai.com/auth"] as? [String: Any]
        return Credentials(accessToken: token, refreshToken: object?["refresh_token"] as? String ?? previous?.refreshToken,
                           accountID: auth?["chatgpt_account_id"] as? String ?? previous?.accountID,
                           expiresAt: (claims?["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(object?["expires_in"] as? Double ?? 3600))
    }
    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var value = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        guard let data = Data(base64Encoded: value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    private static func request(_ url: String, body: [String: String]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
    private static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw ModelConnectionError.message("Codex вернул HTTP \(response.statusCode). Проверьте подключение и повторите вход.")
        }
    }
}
