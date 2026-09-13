import CryptoKit
import Foundation
import Observation
import Security
import StudyCore


public enum ModelCatalog {
    public struct Entry: Identifiable, Sendable {
        public var id: String
        public var title: String
        public var images: Bool
        public var tools: Bool
        public var detail: String
    }
    public static let examples: [Entry] = [
        .init(id: "mlx-community/SmolVLM-256M-Instruct-4bit", title: "SmolVLM · 256M · для 4 ГБ", images: true, tools: false,
              detail: "Первый выбор для устройства с 4 ГБ: один кадр 512 × 512, короткий контекст. Качество японской рукописи нужно проверять на своих примерах."),
        .init(id: "mlx-community/SmolVLM-500M-Instruct-4bit", title: "SmolVLM · 500M · больше возможностей", images: true, tools: false,
              detail: "Следующий вариант для сравнения качества. Требует больше памяти; перед запуском проверяется свободная память."),
        .init(id: "mlx-community/gemma-3-1b-it-4bit", title: "Gemma 3 · 1B · только текст", images: false, tools: false,
              detail: "Gemma 3 1B не читает изображения. Это текстовый вариант для устройств с большим запасом памяти; бюджет режима 4 ГБ может отклонить запуск.")
    ]
    public static func entry(for id: String) -> Entry? { examples.first { $0.id == id } }
    public static func validID(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        return (1...2).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }
    public static func normalizedID(_ input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if validID(input) { return input }
        guard let url = URL(string: input), url.scheme == "https", url.host == "huggingface.co", url.user == nil, url.password == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard !parts.isEmpty, parts.count <= 2 else { return nil }
        let id = parts.joined(separator: "/")
        return validID(id) ? id : nil
    }
    public static var modelsRoot: URL { URL.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true) }
    public static func directory(for id: String) throws -> URL {
        guard validID(id) else { throw StudyError.modelUnavailable("Нужен model ID в формате автор/модель.") }
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return modelsRoot.appendingPathComponent(key, isDirectory: true)
    }
    public static func isDownloaded(_ id: String) -> Bool {
        guard let url = try? directory(for: id) else { return false }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent(".complete").path)
    }
    public static func checkMemoryBudget(_ id: String) throws {
        let directory = try directory(for: id)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        var weights: UInt64 = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "safetensors" else { continue }
            weights += UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        try LocalInferenceLimits().validate(weightBytes: weights, availableMemory: LocalInference.availableMemory)
    }
}

public enum APIKeyStore {
    public static func read(account: String = "provider-key") -> String {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.study.workspace", kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    public static func save(_ key: String, account: String = "provider-key") throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.study.workspace", kSecAttrAccount as String: account]
        if key.isEmpty { SecItemDelete(query as CFDictionary); return }
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        var create = query; create[kSecValueData as String] = data; create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(create as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

@MainActor @Observable
public final class ModelDownloadManager {
    public private(set) var running = false
    public private(set) var progress = 0.0
    public private(set) var status = ""
    public private(set) var activeID: String?
    private var task: Task<Void, Never>?
    public init() {}
    public func cancel() { task?.cancel() }
    public func remove(_ id: String) throws {
        guard !running else { throw StudyError.modelUnavailable("Сначала остановите загрузку.") }
        let directory = try ModelCatalog.directory(for: id)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        status = "Модель удалена"
    }
    public func download(_ rawID: String, inspection: HFInspection? = nil) {
        guard !running else { return }
        guard let id = ModelCatalog.normalizedID(rawID) else { status = "Укажите ID модели или ссылку на её страницу Hugging Face."; return }
        running = true; activeID = id; progress = 0; status = "Получение списка файлов…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { running = false; task = nil }
            do { try await fetch(id, inspection: inspection); status = "Модель загружена"; progress = 1 }
            catch is CancellationError { status = "Загрузка остановлена. Готовые файлы сохранены для повтора." }
            catch { status = error.localizedDescription }
        }
    }
    private func fetch(_ id: String, inspection: HFInspection?) async throws {
        let directory = try ModelCatalog.directory(for: id), fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifestURL = directory.appendingPathComponent(".download.json")
        let hub = HuggingFaceHub()
        let repository: HFRepository
        let metadata: HFInspection
        if let saved = try? Data(contentsOf: manifestURL) {
            repository = try JSONDecoder().decode(HFRepository.self, from: saved)
            if let inspection, inspection.repository.sha == repository.sha { metadata = inspection }
            else { metadata = try await hub.inspect(id, revision: repository.sha) }
        }
        else {
            if let inspection { metadata = inspection } else { metadata = try await hub.inspect(id) }
            repository = metadata.repository
            try JSONEncoder().encode(repository).write(to: manifestURL, options: .atomic)
        }
        try repository.validateLayout()
        var profile = DeviceModelProfile.capture()
        // Existing complete files do not need space a second time during resume.
        var remaining: UInt64 = 0
        for file in repository.downloadableFiles {
            if let size = file.byteCount, let existing = try? directory.appendingPathComponent(file.rfilename).resourceValues(forKeys: [.fileSizeKey]).fileSize, UInt64(existing) == size { continue }
            let addition = remaining.addingReportingOverflow(file.byteCount ?? 0)
            guard !addition.overflow else { throw HFHubError.message("Некорректный размер файлов модели.") }
            remaining = addition.partialValue
        }
        if let free = profile.freeStorage, remaining > free || free - remaining < 64 * 1024 * 1024 { throw HFHubError.message("На устройстве не хватает места для загрузки модели.") }
        profile = DeviceModelProfile(identifier: profile.identifier, name: profile.name, systemVersion: profile.systemVersion, physicalMemory: profile.physicalMemory,
                                     availableMemory: profile.availableMemory, freeStorage: nil, gpuName: profile.gpuName, isSimulator: profile.isSimulator)
        let assessment = ModelDeviceAssessment.evaluate(metadata, device: profile)
        guard assessment.canDownload else { throw HFHubError.message(assessment.reason) }
        let files = repository.downloadableFiles
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            guard !file.rfilename.hasPrefix("/"), !file.rfilename.split(separator: "/").contains("..") else { throw StudyError.invalidPath }
            let target = directory.appendingPathComponent(file.rfilename)
            if let expected = file.byteCount, let existing = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, UInt64(existing) == expected { progress = Double(index + 1) / Double(files.count); continue }
            status = file.rfilename
            let fileURL = try HuggingFaceHub.fileURL(id: id, revision: repository.sha, name: file.rfilename)
            let totalFiles = files.count
            let delegate = DownloadProgress { [weak self] fraction in
                Task { @MainActor in self?.progress = (Double(index) + fraction) / Double(totalFiles) }
            }
            let request = try HuggingFaceHub.authorizedRequest(fileURL, token: HFTokenStore.read())
            let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
            try HuggingFaceHub.check(response); try Task.checkCancellation()
            if let expected = file.byteCount, let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize, UInt64(size) != expected {
                throw StudyError.modelUnavailable("Неполный файл \(file.rfilename). Повторите загрузку.")
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: target) }
            progress = Double(index + 1) / Double(files.count)
        }
        try Data(repository.sha.utf8).write(to: directory.appendingPathComponent(".complete"), options: .atomic)
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Double) -> Void
    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(HuggingFaceHub.redirectedRequest(request)) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
}
