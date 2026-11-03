// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Sommelier",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "SommelierCore"),
        .executableTarget(name: "Sommelier", dependencies: ["SommelierCore"]),
        .executableTarget(name: "mbprobe", dependencies: ["SommelierCore"]),
        .executableTarget(name: "mbdummy"),
        .testTarget(name: "SommelierCoreTests", dependencies: ["SommelierCore"]),
    ]
)
