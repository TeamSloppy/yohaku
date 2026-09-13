import AnyLanguageModel
import Foundation
import Testing
@testable import StudyIntelligence

@Suite(.serialized) struct SloppyConnectionTests {
    @Test(arguments: [false, true]) func generationUsesSavedServerAndRunsToolsLocally(streaming: Bool) async throws {
        SloppyTestURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://sloppy.test/v1/providers/inference")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            let data: Data
            if let body = request.httpBody { data = body }
            else {
                let input = try #require(request.httpBodyStream)
                input.open(); defer { input.close() }
                var body = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while input.hasBytesAvailable {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                data = body
            }
            let body = try JSONDecoder().decode(SloppyInferenceRequest.self, from: data)
            #expect(body.model == "openai-oauth:chosen-model")
            #expect(body.tools.map(\.name) == ["local_note_probe"])
            let hasOutput = body.transcript.contains { if case .toolOutput = $0 { true } else { false } }
            let response = SloppyInferenceResponse(text: hasOutput ? "Ответ из Sloppy" : "", toolCalls: hasOutput ? [] : [
                .init(id: "call-1", toolName: "local_note_probe", arguments: GeneratedContent("read"))
            ])
            let encoded = try JSONEncoder().encode(response)
            if body.stream == true {
                return Data("event: snapshot\ndata: \(String(decoding: encoded, as: UTF8.self))\n\nevent: complete\ndata: \(String(decoding: encoded, as: UTF8.self))\n\n".utf8)
            }
            return encoded
        }
        defer { SloppyTestURLProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SloppyTestURLProtocol.self]
        let http = URLSession(configuration: config)
        defer { http.invalidateAndCancel() }
        let counter = ToolCounter()
        let model = NetworkLanguageModel(baseURL: "https://sloppy.test/v1", accessToken: "test-token", model: "openai-oauth:chosen-model", session: http)
        let session = LanguageModelSession(model: model, tools: [ProbeTool(counter: counter)])
        if streaming {
            var last = ""
            for try await value in session.streamResponse(to: "Прочитай заметку", generating: String.self) { last = value.content }
            #expect(last == "Ответ из Sloppy")
        } else {
            let response = try await session.respond(to: "Прочитай заметку", generating: String.self)
            #expect(response.content == "Ответ из Sloppy")
        }
        #expect(await counter.count == 1)
    }
}

private actor ToolCounter { var count = 0; func increment() { count += 1 } }
private struct ProbeTool: Tool {
    let name = "local_note_probe"
    let description = "Read a local test note"
    let counter: ToolCounter
    func call(arguments: String) async throws -> String { await counter.increment(); return "Local note" }
}
private final class SloppyTestURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> Data)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let callback = Self.handler else { throw URLError(.unknown) }
            let data = try callback(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
