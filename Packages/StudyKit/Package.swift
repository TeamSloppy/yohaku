// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StudyKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "StudyCore", targets: ["StudyCore"]),
        .library(name: "StudyCanvas", targets: ["StudyCanvas"]),
        .executable(name: "yohaku-canvas-maintenance", targets: ["CanvasMaintenanceCLI"])
    ],
    targets: [
        .target(name: "StudyCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "StudyCanvas", dependencies: ["StudyCore"]),
        .executableTarget(name: "CanvasMaintenanceCLI", dependencies: ["StudyCore"]),
        .testTarget(name: "StudyCoreTests", dependencies: ["StudyCore"])
    ]
)
