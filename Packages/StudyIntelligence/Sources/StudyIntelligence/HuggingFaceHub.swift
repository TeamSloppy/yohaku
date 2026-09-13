import Foundation
import StudyCore

public struct HFModel: Identifiable, Hashable, Sendable {
    public let id: String
    public var task: String?
    public var library: String?
    public var tags: [String]
    public var downloads: Int
    public var gated: Bool
    public var isPrivate: Bool
    public var modelURL: URL { URL(string: "https://huggingface.co/" + id)! }

    public init(id: String, task: String? = nil, library: String? = nil, tags: [String] = [], downloads: Int = 0, gated: Bool = false, isPrivate: Bool = false) {
        self.id = id; self.task = task; self.library = library; self.tags = tags; self.downloads = downloads; self.gated = gated; self.isPrivate = isPrivate
    }
    init(json: [String: Any]) throws {
        guard let id = json["id"] as? String ?? json["modelId"] as? String, ModelCatalog.validID(id) else { throw StudyError.invalidPath }
        self.init(id: id, task: json["pipeline_tag"] as? String, library: json["library_name"] as? String,
                  tags: json["tags"] as? [String] ?? [], downloads: json["downloads"] as? Int ?? 0,
                  gated: (json["gated"] as? Bool == true) || (["auto", "manual"].contains(json["gated"] as? String ?? "")), isPrivate: json["private"] as? Bool ?? false)
    }
}

public struct HFModelFile: Codable, Sendable, Equatable {
    public let rfilename: String
    public let size: UInt64?
    public let lfs: LFS?
    public struct LFS: Codable, Sendable, Equatable { public let size: UInt64? }
    public var byteCount: UInt64? { size ?? lfs?.size }
    public init(name: String, size: UInt64?) { rfilename = name; self.size = size; lfs = nil }
}

/// Also decodes the old download manifest, preserving interrupted downloads.
public struct HFRepository: Codable, Sendable {
    public let sha: String
    public let siblings: [HFModelFile]
    public init(sha: String, files: [HFModelFile]) { self.sha = sha; siblings = files }
    public var weightFiles: [HFModelFile] { siblings.filter { !$0.rfilename.contains("/") && !$0.rfilename.hasPrefix(".") && $0.rfilename.hasSuffix(".safetensors") } }
    public var downloadableFiles: [HFModelFile] {
        let extensions = ["json", "safetensors", "model", "txt", "tiktoken", "jinja"]
        return siblings.filter { file in
            !file.rfilename.contains("/") && !file.rfilename.hasPrefix(".") && extensions.contains((file.rfilename as NSString).pathExtension)
        }
    }
    public var weightBytes: UInt64? { Self.total(weightFiles) }
    public var downloadBytes: UInt64? { Self.total(downloadableFiles) }
    private static func total(_ files: [HFModelFile]) -> UInt64? {
        guard !files.isEmpty else { return nil }
        var total: UInt64 = 0
        for file in files {
            guard let size = file.byteCount else { return nil }
            let addition = total.addingReportingOverflow(size)
            guard !addition.overflow else { return nil }; total = addition.partialValue
        }
        return total
    }
    public func validateLayout() throws {
        guard siblings.contains(where: { $0.rfilename == "config.json" }), !weightFiles.isEmpty else {
            throw HFHubError.message("Для MLX нужны config.json и safetensors в корне репозитория. Откройте MLX-версию модели.")
        }
        if weightFiles.count > 1 {
            guard siblings.contains(where: { $0.rfilename == "model.safetensors.index.json" }),
                  !weightFiles.contains(where: { $0.rfilename == "model.safetensors" }) else {
                throw HFHubError.message("В репозитории несколько наборов весов. Выберите отдельный репозиторий нужного варианта модели.")
            }
        }
    }
}

public struct HFInspection: Sendable {
    public let model: HFModel
    public let repository: HFRepository
    public let modelType: String?
    public let isMLX: Bool
    public let supportsImages: Bool?
    public let quantizationBits: Int?
    public let license: String?
    public let configurationProblem: String?

    init(model: HFModel, repository: HFRepository, configuration: Data, license: String? = nil) throws {
        guard let config = try JSONSerialization.jsonObject(with: configuration) as? [String: Any] else { throw HFHubError.message("Не удалось прочитать config.json.") }
        self.model = model; self.repository = repository; self.license = license
        modelType = config["model_type"] as? String
        isMLX = model.library == "mlx" || model.tags.contains("mlx")
        let quant = config["quantization"] as? [String: Any] ?? config["quantization_config"] as? [String: Any]
        quantizationBits = quant?["bits"] as? Int
        if let type = modelType {
            if ArchitectureSupport.vision.contains(type) && (config["vision_config"] != nil || !ArchitectureSupport.text.contains(type)) { supportsImages = true }
            else if ArchitectureSupport.text.contains(type) { supportsImages = false }
            else { supportsImages = model.task == "image-text-to-text" ? true : nil }
        } else { supportsImages = nil }
        if let type = modelType, ["idefics3", "smolvlm"].contains(type) {
            do { _ = try SmolVisionPlan(configuration: configuration); configurationProblem = nil }
            catch { configurationProblem = error.localizedDescription }
        } else { configurationProblem = nil }
    }
}

public enum HFHubError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum HFTokenStore {
    public static func read() -> String { APIKeyStore.read(account: "huggingface-read-token") }
    public static func save(_ token: String) throws { try APIKeyStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines), account: "huggingface-read-token") }
}

public struct HFSearchPage: Sendable { public let models: [HFModel]; public let nextPage: URL? }

public struct HuggingFaceHub: Sendable {
    private let session: URLSession
    private let token: @Sendable () -> String
    public init(session: URLSession? = nil, token: @escaping @Sendable () -> String = { HFTokenStore.read() }) {
        if let session { self.session = session }
        else { let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 25; self.session = URLSession(configuration: config, delegate: HFRedirectPolicy(), delegateQueue: nil) }
        self.token = token
    }
    public static func searchURL(query: String, mlxOnly: Bool, task: String?, maximumParameters: UInt64? = nil) -> URL {
        var url = URLComponents(string: "https://huggingface.co/api/models")!
        var items = [URLQueryItem(name: "search", value: query), .init(name: "sort", value: "downloads"), .init(name: "direction", value: "-1"), .init(name: "limit", value: "30"), .init(name: "full", value: "true")]
        if mlxOnly { items.append(.init(name: "filter", value: "mlx")) }
        if let task { items.append(.init(name: "pipeline_tag", value: task)) }
        if let maximumParameters { items.append(.init(name: "num_parameters", value: "min:0,max:\(maximumParameters)")) }
        url.queryItems = items; return url.url!
    }
    public func search(query: String, mlxOnly: Bool, task: String?, maximumParameters: UInt64? = nil, page: URL? = nil) async throws -> HFSearchPage {
        let url = page ?? Self.searchURL(query: query, mlxOnly: mlxOnly, task: task, maximumParameters: maximumParameters)
        guard Self.isSearchPage(url) else { throw StudyError.invalidPath }
        let (data, response) = try await read(url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw HFHubError.message("Неожиданный ответ каталога.") }
        return HFSearchPage(models: json.compactMap { try? HFModel(json: $0) }, nextPage: Self.nextPage(from: response.value(forHTTPHeaderField: "Link")))
    }
    public func inspect(_ id: String, revision: String? = nil) async throws -> HFInspection {
        let (model, repository, license) = try await repositoryInfo(id, revision: revision)
        let (config, _) = try await read(Self.fileURL(id: id, revision: repository.sha, name: "config.json"))
        return try HFInspection(model: model, repository: repository, configuration: config, license: license)
    }
    public func repository(_ id: String) async throws -> HFRepository { try await repositoryInfo(id).1 }
    private func repositoryInfo(_ id: String, revision: String? = nil) async throws -> (HFModel, HFRepository, String?) {
        guard ModelCatalog.validID(id) else { throw StudyError.invalidPath }
        if let revision { _ = try Self.fileURL(id: id, revision: revision, name: "config.json") }
        let suffix = revision.map { "/revision/" + $0 } ?? ""
        let (data, _) = try await read(URL(string: "https://huggingface.co/api/models/\(id)\(suffix)?blobs=true")!)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HFHubError.message("Не удалось прочитать карточку модели.") }
        let model = try HFModel(json: json), repository = try JSONDecoder().decode(HFRepository.self, from: data)
        let card = json["cardData"] as? [String: Any]
        let license = card?["license"] as? String ?? model.tags.first(where: { $0.hasPrefix("license:") }).map { String($0.dropFirst(8)) }
        return (model, repository, license)
    }
    public static func fileURL(id: String, revision: String, name: String) throws -> URL {
        guard ModelCatalog.validID(id), !revision.isEmpty, revision.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              !name.isEmpty, !name.hasPrefix("/"), !name.split(separator: "/").contains(".."), !name.contains("\\") else { throw StudyError.invalidPath }
        return URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/")!.appendingPathComponent(name)
    }
    public static func authorizedRequest(_ url: URL, token: String) throws -> URLRequest {
        guard url.scheme == "https", url.host == "huggingface.co", url.user == nil, url.password == nil else { throw StudyError.invalidPath }
        var request = URLRequest(url: url)
        if !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func read(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let request = try Self.authorizedRequest(url, token: token())
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard data.count <= 8 * 1024 * 1024, let http = response as? HTTPURLResponse else { throw HFHubError.message("Ответ метаданных слишком большой.") }
        return (data, http)
    }
    public static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw HFHubError.message("Нет ответа Hugging Face.") }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw HFHubError.message("Нужен действующий Hugging Face read token. Добавьте его в настройках каталога.")
        case 403: throw HFHubError.message("Нет доступа к модели. Откройте её страницу на Hugging Face и запросите доступ или примите условия, затем повторите.")
        case 404: throw HFHubError.message("Модель/файл не найдены либо репозиторий приватный. Проверьте ID и read token.")
        case 429: throw HFHubError.message("Достигнут лимит запросов Hugging Face. Подождите и повторите поиск.")
        default: throw HFHubError.message("Hugging Face вернул HTTP \(http.statusCode). Повторите позже.")
        }
    }
    static func isSearchPage(_ url: URL) -> Bool { url.scheme == "https" && url.host == "huggingface.co" && url.path == "/api/models" && url.user == nil && url.password == nil }
    static func nextPage(from header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") where part.contains("rel=\"next\"") {
            guard let begin = part.firstIndex(of: "<"), let end = part.firstIndex(of: ">"), begin < end,
                  let url = URL(string: String(part[part.index(after: begin)..<end])), isSearchPage(url) else { continue }
            return url
        }
        return nil
    }
    static func redirectedRequest(_ request: URLRequest) -> URLRequest? {
        guard request.url?.scheme == "https" else { return nil }
        var redirected = request
        if request.url?.host != "huggingface.co" { redirected.setValue(nil, forHTTPHeaderField: "Authorization") }
        return redirected
    }
}

private final class HFRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(HuggingFaceHub.redirectedRequest(request)) }
}
