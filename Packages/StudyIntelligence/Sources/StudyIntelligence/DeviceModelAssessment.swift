import Foundation
import Metal
#if canImport(UIKit)
import UIKit
#endif

public struct DeviceModelProfile: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let systemVersion: String
    public let physicalMemory: UInt64
    public let availableMemory: UInt64?
    public let freeStorage: UInt64?
    public let gpuName: String?
    public let isSimulator: Bool
    public var evaluationMemory: UInt64 { isSimulator ? min(physicalMemory, 4 * 1024 * 1024 * 1024) : physicalMemory }
    public var memoryBudget: UInt64 { LocalInferenceLimits(physicalMemory: evaluationMemory).memoryBudget }

    public init(identifier: String, name: String, systemVersion: String, physicalMemory: UInt64, availableMemory: UInt64?, freeStorage: UInt64?, gpuName: String?, isSimulator: Bool = false) {
        self.identifier = identifier; self.name = name; self.systemVersion = systemVersion; self.physicalMemory = physicalMemory
        self.availableMemory = availableMemory; self.freeStorage = freeStorage; self.gpuName = gpuName; self.isSimulator = isSimulator
    }
    @MainActor public static func capture() -> Self {
        var system = utsname(); uname(&system)
        let identifier = withUnsafeBytes(of: &system.machine) { bytes in String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let gpu = MTLCreateSystemDefaultDevice()?.name
        let capacity = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        #if targetEnvironment(macCatalyst)
        let title = "Mac · " + identifier
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        #elseif canImport(UIKit)
        let title: String
        if ["iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4"].contains(identifier) { title = "iPad Pro 11″ (2018) · A12X" }
        else if ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"].contains(identifier) { title = "iPad Pro 12,9″ (2018) · A12X" }
        else { title = UIDevice.current.model + " · " + identifier }
        let version = "iPadOS " + UIDevice.current.systemVersion
        #else
        let title = "Mac · " + identifier
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        #endif
        return Self(identifier: identifier, name: title, systemVersion: version, physicalMemory: ProcessInfo.processInfo.physicalMemory,
                    availableMemory: LocalInference.availableMemory, freeStorage: capacity.flatMap { $0 >= 0 ? UInt64($0) : nil }, gpuName: gpu, isSimulator: LocalInference.isSimulator)
    }
    public static func size(_ bytes: UInt64?) -> String {
        guard let bytes, bytes <= UInt64(Int64.max) else { return "неизвестно" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

/// Architecture support snapshot of the pinned mlx-swift-lm 2.31.3 registries.
/// This is engine support, not a list of model IDs. New architectures remain visible in the Hub browser.
enum ArchitectureSupport {
    static let text: Set<String> = [
        "mistral", "llama", "phi", "phi3", "phimoe", "gemma", "gemma2", "gemma3", "gemma3_text", "gemma3n",
        "qwen2", "qwen3", "qwen3_moe", "qwen3_next", "qwen3_5", "qwen3_5_moe", "qwen3_5_text", "minicpm",
        "starcoder2", "cohere", "openelm", "internlm2", "deepseek_v3", "granite", "granitemoehybrid", "mimo",
        "mimo_v2_flash", "minimax", "glm4", "glm4_moe", "glm4_moe_lite", "acereason", "falcon_h1", "bitnet",
        "smollm3", "ernie4_5", "lfm2", "baichuan_m1", "exaone4", "gpt_oss", "lille-130m", "olmoe", "olmo2",
        "olmo3", "bailing_moe", "lfm2_moe", "nanochat", "nemotron_h", "afmoe", "jamba_3b", "mistral3", "apertus"
    ]
    static let vision: Set<String> = [
        "paligemma", "qwen2_vl", "qwen2_5_vl", "qwen3_vl", "qwen3_5", "qwen3_5_moe", "idefics3", "gemma3",
        "smolvlm", "fastvlm", "llava_qwen2", "pixtral", "mistral3", "lfm2_vl", "lfm2-vl", "glm_ocr"
    ]
}

public struct ModelDeviceAssessment: Sendable, Equatable {
    public enum Status: String, Sendable { case candidate, tight, tooLarge, unsupported, unknown }
    public let status: Status
    public let reason: String
    public let estimatedMemory: UInt64?
    public var title: String {
        switch status {
        case .candidate: "Кандидат для этого устройства"
        case .tight: "Мало запаса памяти"
        case .tooLarge: "Не проходит бюджет"
        case .unsupported: "Нужен другой формат / адаптер"
        case .unknown: "Нужна проверка"
        }
    }
    public var rank: Int {
        switch status { case .candidate: 0; case .tight: 1; case .unknown: 2; case .tooLarge: 3; case .unsupported: 4 }
    }
    public var canDownload: Bool { status != .unsupported && status != .tooLarge }
    public var recommended: Bool { status == .candidate || status == .tight }

    public static func evaluate(_ model: HFInspection, device: DeviceModelProfile, requiresVision: Bool = false) -> Self {
        let weights = model.repository.weightBytes
        let estimate = weights.flatMap { $0 < UInt64.max / 4 ? $0 * 2 + 512 * 1024 * 1024 : nil }
        func result(_ status: Status, _ reason: String) -> Self { .init(status: status, reason: reason, estimatedMemory: estimate) }
        guard device.gpuName != nil else { return result(.unsupported, "На устройстве не найден Metal GPU для MLX.") }
        guard model.isMLX else { return result(.unsupported, "Это не отмеченная MLX-версия. PyTorch, GGUF и ONNX этим движком не запускаются.") }
        do { try model.repository.validateLayout() } catch { return result(.unsupported, error.localizedDescription) }
        guard let type = model.modelType else { return result(.unknown, "В config.json не указан model_type.") }
        guard ArchitectureSupport.text.contains(type) || ArchitectureSupport.vision.contains(type) else {
            return result(.unsupported, "Для архитектуры \(type) нет адаптера в установленном mlx-swift-lm 2.31.3.")
        }
        if let problem = model.configurationProblem { return result(.unsupported, problem) }
        if requiresVision && model.supportsImages != true { return result(.unsupported, "Эта модель не подтверждена как vision-модель. Выберите режим поиска «Текст».") }
        if let bytes = model.repository.downloadBytes, let free = device.freeStorage, bytes > free || free - bytes < 64 * 1024 * 1024 {
            return result(.tooLarge, "На накопителе недостаточно места для загрузки.")
        }
        guard let estimate, weights != 0 else { return result(.unknown, "Hub не сообщил полный размер весов. Оценить RAM до загрузки не удалось.") }
        guard estimate <= device.memoryBudget else {
            return result(.tooLarge, "Оценка RAM \(DeviceModelProfile.size(estimate)) превышает бюджет приложения \(DeviceModelProfile.size(device.memoryBudget)).")
        }
        if let free = device.availableMemory, free < estimate || free - estimate < 128 * 1024 * 1024 {
            return result(.tight, "По общему объёму RAM модель помещается, но сейчас свободной памяти мало. Закройте тяжёлые приложения и обновите профиль.")
        }
        let text = device.isSimulator ? "Расчёт для условного профиля 4 ГБ; генерация требует физическое устройство." : "Архитектура поддерживается, оценка RAM укладывается в бюджет. Скорость и качество нужно проверить запуском."
        return result(estimate > device.memoryBudget * 4 / 5 ? .tight : .candidate, text)
    }
}
