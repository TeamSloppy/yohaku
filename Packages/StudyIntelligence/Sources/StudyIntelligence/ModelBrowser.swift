import Foundation
import Observation

@MainActor @Observable public final class ModelBrowser {
    public enum Mode: String, CaseIterable, Sendable {
        case recommended, all
        public var title: String {
            switch self {
            case .recommended: String(localized: "Для устройства")
            case .all: String(localized: "Каталог HF")
            }
        }
    }
    public enum TaskKind: String, CaseIterable, Sendable {
        case vision, text, all
        public var title: String {
            switch self {
            case .vision: String(localized: "Изображения")
            case .text: String(localized: "Текст")
            case .all: String(localized: "Все задачи")
            }
        }
        var apiValue: String? { self == .vision ? "image-text-to-text" : self == .text ? "text-generation" : nil }
    }
    public var query = ""
    public var mode: Mode = .recommended
    public var taskKind: TaskKind = .vision
    public var mlxOnly = false
    public private(set) var profile: DeviceModelProfile
    public private(set) var models: [HFModel] = []
    public private(set) var inspections: [String: HFInspection] = [:]
    public private(set) var inspectionErrors: [String: String] = [:]
    public private(set) var loading = false
    public private(set) var inspected = 0
    public private(set) var error: String?
    public private(set) var nextPage: URL?
    private let hub: HuggingFaceHub
    private var work: Task<Void, Never>?
    private var generation = UUID()

    public init(hub: HuggingFaceHub = .init(), profile: DeviceModelProfile? = nil) {
        self.hub = hub; self.profile = profile ?? .capture()
    }
    public var maximumParameters: UInt64 { profile.evaluationMemory <= 4 * 1024 * 1024 * 1024 ? 1_000_000_000 : 3_000_000_000 }
    public func assessment(_ id: String) -> ModelDeviceAssessment? {
        inspections[id].map { ModelDeviceAssessment.evaluate($0, device: profile, requiresVision: taskKind == .vision) }
    }
    public var visibleModels: [HFModel] {
        if mode == .all { return models }
        return models.filter { assessment($0.id)?.recommended == true }.sorted {
            let left = assessment($0.id), right = assessment($1.id)
            if left?.rank != right?.rank { return (left?.rank ?? 9) < (right?.rank ?? 9) }
            return (left?.estimatedMemory ?? .max) < (right?.estimatedMemory ?? .max)
        }
    }
    public func refreshProfile() { profile = .capture() }
    public func cancel() { work?.cancel(); generation = UUID(); loading = false }
    public func changeMode() {
        taskKind = mode == .recommended ? .vision : .all
        search()
    }
    public func search(debounced: Bool = false) {
        work?.cancel(); let id = UUID(); generation = id
        let query = ModelCatalog.normalizedID(query) ?? query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recommended = mode == .recommended
        let onlyMLX = recommended || mlxOnly, task = taskKind.apiValue
        let cap: UInt64? = recommended ? maximumParameters : nil
        models = []; inspections = [:]; inspectionErrors = [:]; inspected = 0; error = nil; nextPage = nil; loading = true
        work = Task {
            do {
                if debounced { try await Task.sleep(for: .milliseconds(350)) }
                var pages = 0
                repeat {
                    let page = try await hub.search(query: query, mlxOnly: onlyMLX, task: task, maximumParameters: cap, page: nextPage)
                    guard generation == id, !Task.isCancelled else { return }
                    append(page); pages += 1
                    await inspect(page.models, generation: id)
                } while recommended && nextPage != nil && visibleModels.count < 6 && pages < 3 && generation == id && !Task.isCancelled
            } catch is CancellationError {} catch { if generation == id { self.error = error.localizedDescription } }
            if generation == id { loading = false }
        }
    }
    public func loadMore() {
        guard let nextPage, !loading else { return }
        let id = generation; loading = true
        work = Task {
            do {
                let page = try await hub.search(query: query, mlxOnly: mode == .recommended || mlxOnly, task: taskKind.apiValue, page: nextPage)
                guard generation == id, !Task.isCancelled else { return }
                append(page); await inspect(page.models, generation: id)
            } catch is CancellationError {} catch { if generation == id { self.error = error.localizedDescription } }
            if generation == id { loading = false }
        }
    }
    public func inspection(_ id: String, refresh: Bool = false) async throws -> HFInspection {
        if !refresh, let existing = inspections[id] { return existing }
        let current = generation
        let value = try await hub.inspect(id)
        if generation == current { inspections[id] = value; inspectionErrors[id] = nil }
        return value
    }
    private func append(_ page: HFSearchPage) {
        let existing = Set(models.map(\.id))
        models += page.models.filter { !existing.contains($0.id) }
        nextPage = page.nextPage
    }
    private func inspect(_ page: [HFModel], generation id: UUID) async {
        // Bounded metadata-only requests. No weights are downloaded by discovery.
        let hub = hub
        await withTaskGroup(of: (String, HFInspection?, String?).self) { group in
            var iterator = page.makeIterator()
            func add(_ model: HFModel) {
                group.addTask {
                    do { return (model.id, try await hub.inspect(model.id), nil) }
                    catch { return (model.id, nil, error.localizedDescription) }
                }
            }
            for _ in 0..<3 { if let model = iterator.next() { add(model) } }
            while let (modelID, value, failure) = await group.next() {
                guard generation == id, !Task.isCancelled else { group.cancelAll(); return }
                inspected += 1
                if let value { inspections[modelID] = value }
                if let failure { inspectionErrors[modelID] = failure }
                if let model = iterator.next() { add(model) }
            }
        }
    }
}
