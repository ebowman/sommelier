// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The proved Lean decision core (LeanCore, DecisionCore and its tests) is part of the package only once scripts/build-lean-core.sh has built
// build/LeanCore/LeanCore.xcframework (`make build` and `make test` do that first). Without it, a plain `swift build` / `swift test` still works
// and simply skips them, so a fresh clone needs no Lean. THIS BECOMES MANDATORY AT ejb.7, when SommelierCore depends on DecisionCore:
// then the xcframework must exist for every build and this condition goes away.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasLeanCore = FileManager.default.fileExists(atPath: packageDir + "/build/LeanCore/LeanCore.xcframework")

var targets: [Target] = [
    .target(name: "SommelierCore"),
    .executableTarget(name: "Sommelier", dependencies: ["SommelierCore"]),
    .executableTarget(name: "mbprobe", dependencies: ["SommelierCore"]),
    .executableTarget(name: "mbdummy"),
    .testTarget(name: "SommelierCoreTests", dependencies: ["SommelierCore"]),
]
if hasLeanCore {
    targets += [
        .binaryTarget(name: "LeanCore", path: "build/LeanCore/LeanCore.xcframework"),
        .target(name: "DecisionCore", dependencies: ["LeanCore"], linkerSettings: [.linkedLibrary("c++")]),
        .testTarget(name: "DecisionCoreTests", dependencies: ["DecisionCore"]),
    ]
}

let package = Package(
    name: "Sommelier",
    platforms: [.macOS(.v26)],
    targets: targets
)
