// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StudyKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "StudyCore", targets: ["StudyCore"]),
        .library(name: "StudyCanvas", targets: ["StudyCanvas"])
    ],
    targets: [
        .target(name: "StudyCore"),
        .target(name: "StudyCanvas", dependencies: ["StudyCore"]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)
