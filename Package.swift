// swift-tools-version: 6.2
import PackageDescription
import Foundation

// The proved Lean decision core (LeanCore, DecisionCore and its tests) needs build/LeanCore/LeanCore.xcframework (`make build` and `make test`
// run scripts/build-lean-core.sh first). Since sommelier-ejb.13 SommelierCore depends on DecisionCore (ReadAdapter produces its `Read`), so the
// xcframework is MANDATORY for every build: a clean clone runs `make lean-core` (or `scripts/build-lean-core.sh`) first.

// SwiftPM prints the manifest's fatalError text, so a build without the core fails naming the fix.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
if !FileManager.default.fileExists(atPath: packageDir + "/build/LeanCore/LeanCore.xcframework") {
    fatalError("build/LeanCore/LeanCore.xcframework is missing: the Lean decision core is required for every build. Run `make lean-core` (or `make test`) first.")
}

let targets: [Target] = [
    .target(name: "SommelierCore", dependencies: ["DecisionCore"]),
    .executableTarget(name: "Sommelier", dependencies: ["SommelierCore"]),
    .executableTarget(name: "mbprobe", dependencies: ["SommelierCore"]),
    .executableTarget(name: "mbdummy"),
    .testTarget(name: "SommelierCoreTests", dependencies: ["SommelierCore", "DecisionCore"], exclude: ["Fixtures"]),
    // The heavy ReadAdapter property test: a separate target so `make test` can run it in its own `swift test` invocation (see Makefile).
    .testTarget(name: "AdapterPropertyTests", dependencies: ["SommelierCore", "DecisionCore"]),
    .binaryTarget(name: "LeanCore", path: "build/LeanCore/LeanCore.xcframework"),
    .target(name: "DecisionCore", dependencies: ["LeanCore"], linkerSettings: [.linkedLibrary("c++")]),
    .testTarget(name: "DecisionCoreTests", dependencies: ["DecisionCore", "SommelierCore"]),
]

let package = Package(
    name: "Sommelier",
    platforms: [.macOS(.v26)],
    targets: targets
)
