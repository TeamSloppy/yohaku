import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import StudyCore
import Tokenizers

/// Derived from the model configuration, never from the source screenshot dimensions.
struct SmolVisionPlan: Equatable, Sendable {
    let imageSize: Int
    let patchSize: Int
    let scaleFactor: Int
    let hiddenSize: Int
    let imageTokenID: Int
    let quantizationBits: Int?
    let quantizationGroupSize: Int?
    var patchCount: Int { (imageSize / patchSize) * (imageSize / patchSize) }
    var imageTokenCount: Int { patchCount / (scaleFactor * scaleFactor) }

    init(configuration: Data) throws {
        struct Configuration: Decodable {
            struct Vision: Decodable { let image_size: Int; let patch_size: Int; let hidden_size: Int }
            struct Quantization: Decodable { let bits: Int; let group_size: Int }
            let model_type: String
            let vision_config: Vision
            let scale_factor: Int
            let image_token_id: Int
            let image_token_index: Int?
            let quantization: Quantization?
        }
        let config = try JSONDecoder().decode(Configuration.self, from: configuration)
        imageSize = config.vision_config.image_size
        patchSize = config.vision_config.patch_size
        scaleFactor = config.scale_factor
        hiddenSize = config.vision_config.hidden_size
        imageTokenID = config.image_token_index ?? config.image_token_id
        quantizationBits = config.quantization?.bits
        quantizationGroupSize = config.quantization?.group_size
        guard ["idefics3", "smolvlm"].contains(config.model_type), imageSize > 0, imageSize <= 512,
              patchSize > 0, patchSize <= imageSize, scaleFactor > 0, scaleFactor <= 16,
              hiddenSize > 0, imageTokenID >= 0, imageTokenID == config.image_token_id,
              imageSize % patchSize == 0, (imageSize / patchSize) % scaleFactor == 0 else {
            throw StudyError.modelUnavailable("Несовместимая конфигурация SmolVLM. Выберите SmolVLM 256M или 500M из списка.")
        }
    }

    func validatePositionEmbedding(shape: [Int], dtype: String? = nil, scaleShape: [Int]? = nil) throws {
        if shape == [patchCount, hiddenSize] && dtype != "U32" { return }
        if dtype == "U32", let bits = quantizationBits, [2, 4, 8].contains(bits),
           let group = quantizationGroupSize, group > 0, hiddenSize % group == 0,
           hiddenSize * bits % 32 == 0, shape == [patchCount, hiddenSize * bits / 32],
           scaleShape == [patchCount, hiddenSize / group] {
            return
        }
        throw StudyError.modelUnavailable("Размеры vision-весов не совпадают с конфигурацией или формат квантования не поддерживается.")
    }

    /// Safetensors headers contain shapes; inspect them without allocating the weights.
    func validateWeights(in directory: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var found = false
        for file in files where file.pathExtension == "safetensors" {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            guard prefix.count == 8 else { throw StudyError.modelUnavailable("Повреждён заголовок весов модели.") }
            let count = prefix.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
            guard count > 0, count <= 16 * 1024 * 1024 else { throw StudyError.modelUnavailable("Некорректный заголовок safetensors.") }
            let data = try handle.read(upToCount: Int(count)) ?? Data()
            guard data.count == count, let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw StudyError.modelUnavailable("Неполный заголовок весов модели.")
            }
            for (name, value) in header where name.hasSuffix("vision_model.embeddings.position_embedding.weight") {
                guard let tensor = value as? [String: Any], let shape = tensor["shape"] as? [Int] else {
                    throw StudyError.modelUnavailable("Не удалось прочитать форму позиционных эмбеддингов.")
                }
                let scaleName = String(name.dropLast("weight".count)) + "scales"
                let scaleShape = (header[scaleName] as? [String: Any])?["shape"] as? [Int]
                try validatePositionEmbedding(shape: shape, dtype: tensor["dtype"] as? String, scaleShape: scaleShape); found = true
            }
        }
        guard found else { throw StudyError.modelUnavailable("В модели не найдены позиционные vision-эмбеддинги SmolVLM.") }
    }
}

/// App-owned replacement for mlx-swift-lm 2.31.3's fixed-384 Idefics3Processor.
/// One aspect-preserving frame, one block of image tokens; no tile expansion.
struct SmolVisionProcessor: UserInputProcessor {
    let plan: SmolVisionPlan
    let tokenizer: any Tokenizer
    let maximumInputTokens: Int
    private let mean: [CGFloat]
    private let std: [CGFloat]

    init(plan: SmolVisionPlan, configuration: Data, tokenizer: any Tokenizer, maximumInputTokens: Int) throws {
        struct ProcessorConfig: Decodable { let image_mean: [CGFloat]; let image_std: [CGFloat] }
        let config = try JSONDecoder().decode(ProcessorConfig.self, from: configuration)
        guard config.image_mean.count == 3, config.image_std.count == 3,
              config.image_mean.allSatisfy(\.isFinite), config.image_std.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw StudyError.modelUnavailable("Некорректная нормализация изображения в конфигурации модели.")
        }
        guard tokenizer.convertTokenToId("<image>") == plan.imageTokenID,
              tokenizer.convertTokenToId("<fake_token_around_image>") != nil else {
            throw StudyError.modelUnavailable("Токенизатор не соответствует vision-конфигурации SmolVLM.")
        }
        self.plan = plan; self.tokenizer = tokenizer; self.maximumInputTokens = maximumInputTokens
        mean = config.image_mean; std = config.image_std
    }

    func expandedImageTokens(_ tokens: [Int], hasImage: Bool) throws -> [Int] {
        let count = tokens.filter { $0 == plan.imageTokenID }.count
        guard count == (hasImage ? 1 : 0) else {
            throw StudyError.modelUnavailable("SmolVLM ожидает один маркер изображения. Отправьте один выделенный фрагмент без специальных image-токенов в тексте.")
        }
        guard hasImage else { return tokens }
        guard let boundary = tokenizer.convertTokenToId("<fake_token_around_image>") else {
            throw StudyError.modelUnavailable("Отсутствует image boundary token.")
        }
        return tokens.flatMap { token in
            guard token == plan.imageTokenID else { return [token] }
            // This is the global view of the image, not a spatial tile.
            let global = tokenizer.convertTokenToId("<global-img>").map { [$0] } ?? []
            return [boundary] + global + Array(repeating: token, count: plan.imageTokenCount) + [boundary]
        }
    }

    func prepare(input: UserInput) async throws -> LMInput {
        guard input.videos.isEmpty, input.images.count <= 1 else {
            throw StudyError.modelUnavailable("Компактный режим поддерживает одну картинку за запрос.")
        }
        guard input.tools?.isEmpty != false else {
            throw StudyError.modelUnavailable("SmolVLM в компактном режиме отвечает на вопросы без вызова инструментов.")
        }
        let messages = Qwen2VLMessageGenerator().generate(from: input)
        let rendered = try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: input.additionalContext)
        let tokens = try expandedImageTokens(rendered, hasImage: !input.images.isEmpty)
        guard tokens.count <= maximumInputTokens else {
            throw StudyError.modelUnavailable("Контекст слишком длинный для компактной модели. Выделите меньший фрагмент или сократите вопрос.")
        }
        try Task.checkCancellation()
        let tokenArray = MLXArray(tokens).expandedDimensions(axis: 0)
        let text = LMInput.Text(tokens: tokenArray, mask: ones(like: tokenArray))
        guard let source = input.images.first else { return LMInput(text: text, image: nil) }
        let image = try source.asCIImage()
        let pixels = try preparePixels(image)
        guard pixels.shape == [1, plan.imageSize, plan.imageSize, 3] else {
            throw StudyError.modelUnavailable("Препроцессор сформировал неправильные размеры изображения.")
        }
        return LMInput(text: text, image: .init(pixels: pixels))
    }

    func preparePixels(_ source: CIImage) throws -> MLXArray {
        let image = try normalizedImage(source)
        let pixels = MediaProcessing.asMLXArray(image)
        if pixels.shape == [plan.imageSize, plan.imageSize, 3] { return pixels.expandedDimensions(axis: 0) }
        if pixels.shape == [1, 3, plan.imageSize, plan.imageSize] { return pixels.transposed(0, 2, 3, 1) }
        throw StudyError.modelUnavailable("Неподдерживаемый формат пикселей SmolVLM: \(pixels.shape).")
    }

    func normalizedImage(_ source: CIImage) throws -> CIImage {
        guard !source.extent.isEmpty, !source.extent.isInfinite, source.extent.width.isFinite, source.extent.height.isFinite else {
            throw StudyError.modelUnavailable("Изображение пустое или имеет некорректный размер.")
        }
        let side = CGFloat(plan.imageSize)
        let scale = min(side / source.extent.width, side / source.extent.height)
        var image = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
        image = MediaProcessing.inSRGBToneCurveSpace(image)
        image = MediaProcessing.resampleBicubic(image, to: CGSize(width: source.extent.width * scale, height: source.extent.height * scale))
        image = image.transformed(by: CGAffineTransform(translationX: (side - image.extent.width) / 2 - image.extent.minX,
                                                      y: (side - image.extent.height) / 2 - image.extent.minY))
        let square = CGRect(x: 0, y: 0, width: side, height: side)
        image = image.composited(over: CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: square)).cropped(to: square)
        image = MediaProcessing.normalize(image, mean: (mean[0], mean[1], mean[2]), std: (std[0], std[1], std[2]))
        return image
    }
}

enum LocalModelCompatibility {
    /// Install before ALM loads/caches its ModelContext. No downloaded config or dependency source is edited.
    @discardableResult static func prepare(directory: URL, maximumInputTokens: Int) async throws -> [String] {
        let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = config["model_type"] as? String else {
            throw StudyError.modelUnavailable("Не удалось прочитать тип локальной модели.")
        }
        guard ["idefics3", "smolvlm"].contains(type) else { return [] }
        let plan = try SmolVisionPlan(configuration: data)
        try plan.validateWeights(in: directory)
        for name in ["Idefics3Processor", "SmolVLMProcessor"] {
            await VLMProcessorTypeRegistry.shared.registerProcessorType(name) { data, tokenizer in
                try SmolVisionProcessor(plan: plan, configuration: data, tokenizer: tokenizer, maximumInputTokens: maximumInputTokens)
            }
        }
        return ["<end_of_utterance>"]
    }
}
