import AnyLanguageModel
import Foundation
import Testing
@testable import StudyIntelligence

struct NetworkProvidersTests {
    @Test func oldSettingsSurviveNewProviderFields() throws {
        let legacy = Data(#"{"provider":"network","localID":"local/model","endpoint":"https://old.example/v1","remoteID":"old-model","supportsImages":false,"supportsTools":true}"#.utf8)
        let config = try JSONDecoder().decode(ModelConfiguration.self, from: legacy)
        #expect(config.provider == .network)
        #expect(config.endpoint == "https://old.example/v1")
        #expect(config.remoteID == "old-model")
        #expect(config.localID == "local/model")
        #expect(config.supportsTools)
        #expect(!config.supportsImages)
        #expect(config.codexModel.isEmpty && config.sloppyModel.isEmpty)
        #expect(try JSONDecoder().decode(ModelConfiguration.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func secretsAreBoundToProviderAndEndpoint() {
        var config = ModelConfiguration()
        config.provider = .network
        config.endpoint = "https://one.example/v1"
        let first = config.credentialAccount
        config.endpoint = "https://two.example/v1"
        #expect(config.credentialAccount != first)
        config.provider = .sloppy; config.sloppyEndpoint = "https://one.example/v1"
        #expect(config.credentialAccount != first)
    }

    @Test func codexDeviceFlowStoresAndRefreshesOnlyAfterApproval() async throws {
        let store = AuthMemoryStore()
        let client = CodexAuthorization(transport: { request in
            let response: String
            switch request.url?.path {
            case "/api/accounts/deviceauth/usercode":
                response = #"{"device_auth_id":"device","user_code":"TEST-CODE","interval":"5","expires_in":600}"#
            case "/api/accounts/deviceauth/token":
                let body = try #require(request.httpBody)
                let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: String])
                #expect(object["device_auth_id"] == "device")
                #expect(object["user_code"] == "TEST-CODE")
                response = #"{"authorization_code":"approved-code","code_verifier":"verifier"}"#
            case "/oauth/token":
                let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
                if body.contains("grant_type=refresh_token") {
                    #expect(body.contains("refresh_token=refresh-secret"))
                    response = #"{"access_token":"renewed","expires_in":3600}"#
                } else {
                    #expect(body.contains("code=approved-code"))
                    #expect(body.contains("code_verifier=verifier"))
                    response = #"{"access_token":"access-secret","refresh_token":"refresh-secret","expires_in":3600}"#
                }
            default: throw URLError(.unsupportedURL)
            }
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, read: { store.read() }, save: { store.save($0) })
        let code = try await client.start()
        #expect(code.code == "TEST-CODE")
        #expect(code.interval == 5)
        #expect(store.read().isEmpty)
        guard case .connected = try await client.poll(code) else { Issue.record("Expected successful sign-in"); return }
        #expect(await client.isConnected())
        #expect(try await client.credentials().accessToken == "access-secret")
        let refreshed = try await client.credentials(forceRefresh: true)
        #expect(refreshed.accessToken == "renewed")
        #expect(refreshed.refreshToken == "refresh-secret")
        try await client.disconnect()
        #expect(store.read().isEmpty)
    }

    @Test func codexPendingAndSlowDownDoNotSaveCredentials() async throws {
        for (status, body) in [(403, "{}"), (429, #"{"error":"slow_down"}"#)] {
            let store = AuthMemoryStore()
            let client = CodexAuthorization(transport: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, read: { store.read() }, save: { store.save($0) })
            let result = try await client.poll(.init(id: "device", code: "code", interval: 5, expiresIn: 600))
            if status == 403 { guard case .pending = result else { Issue.record("Expected pending"); return } }
            else { guard case .slowDown = result else { Issue.record("Expected slow down"); return } }
            #expect(store.read().isEmpty)
        }
    }

    @Test func codexBodyCarriesImagesInstructionsAndToolOutputs() throws {
        let arguments = try GeneratedContent(json: #"{"operation":"read","path":"note.md"}"#)
        let transcript = Transcript(entries: [
            .instructions(.init(segments: [.text(.init(content: "Yohaku instructions"))], toolDefinitions: [])),
            .prompt(.init(segments: [.text(.init(content: "Explain this")), .image(.init(data: Data([1, 2]), mimeType: "image/png"))], options: .init(), responseFormat: nil)),
            .toolCalls(.init([.init(id: "call", toolName: "notes", arguments: arguments)])),
            .toolOutput(.init(id: "call", toolName: "notes", segments: [.structure(.init(source: "notes", content: GeneratedContent("日本語")))])),
        ])
        let data = try CodexResponsesTransport.body(.init(model: "chosen-model", transcript: transcript, tools: [], options: .init(maximumResponseTokens: 100)))
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "chosen-model")
        #expect(body["instructions"] as? String == "Yohaku instructions")
        #expect(body["stream"] as? Bool == true)
        #expect(body["store"] as? Bool == false)
        #expect(body["max_output_tokens"] == nil)
        let items = try #require(body["input"] as? [[String: Any]])
        let content = try #require(items[0]["content"] as? [[String: Any]])
        #expect(content[1]["image_url"] as? String == "data:image/png;base64,AQI=")
        let serializedArguments = try #require(items[1]["arguments"] as? String)
        let actualArguments = try #require(JSONSerialization.jsonObject(with: Data(serializedArguments.utf8)) as? [String: String])
        let expectedArguments = try #require(JSONSerialization.jsonObject(with: Data(arguments.jsonString.utf8)) as? [String: String])
        #expect(actualArguments == expectedArguments)
        #expect((items[2]["output"] as? String)?.contains("日本語") == true)
    }

    @Test func codexStreamKeepsTextAndDeduplicatesToolCalls() throws {
        var parser = CodexResponseAccumulator()
        try parser.consume(#"data: {"type":"response.output_text.delta","delta":"Привет"}"#)
        try parser.consume(#"data: {"type":"response.output_item.done","item":{"type":"function_call","call_id":"c","name":"notes","arguments":"{}"}}"#)
        try parser.consume(#"data: {"type":"response.completed","response":{"output":[{"type":"function_call","call_id":"c","name":"notes","arguments":"{}"}]}}"#)
        #expect(parser.text == "Привет")
        #expect(parser.completed)
        #expect(parser.calls.count == 1)
        #expect(throws: (any Error).self) { try parser.consume(#"data: {"type":"response.failed"}"#) }
    }

    @Test func sloppyURLPreservesMountPathAndAcceptsV1Suffix() throws {
        #expect(try SloppyRemoteEndpoint.url(base: "https://remote.example/sloppy/v1/", path: "providers/models").path == "/sloppy/v1/providers/models")
        #expect(throws: (any Error).self) { try SloppyRemoteEndpoint.url(base: "file:///tmp", path: "providers/models") }
    }
}

private final class AuthMemoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func read() -> String { lock.withLock { value } }
    func save(_ value: String) { lock.withLock { self.value = value } }
}
