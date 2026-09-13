// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StudyIntelligence",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "StudyIntelligence", targets: ["StudyIntelligence"])],
    dependencies: [
        .package(path: "../StudyKit"),
        .package(url: "https://github.com/huggingface/AnyLanguageModel.git", revision: "701d7e61db7b59db9092f2db62b1567144835b3b", traits: ["MLX"]),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "2.31.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.2.1")
    ],
    targets: [.target(name: "StudyIntelligence", dependencies: [
        .product(name: "StudyCore", package: "StudyKit"),
        .product(name: "StudyCanvas", package: "StudyKit"),
        .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
        .product(name: "MLXVLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ])]
)
