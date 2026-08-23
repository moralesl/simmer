// swift-tools-version: 6.0
// One package, three products (BRIEF.md):
//   SimmerCore — the logic. No AppKit, no printing, no argv, no globals.
//   simmer     — the CLI. argv in, exit code out.
//   simmer-app — the menu bar + guard + notifier; `make app` wraps it into Simmer.app.
import PackageDescription

let package = Package(
    name: "simmer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "simmer", targets: ["simmer"]),
        .executable(name: "simmer-app", targets: ["simmer-app"]),
        .library(name: "SimmerCore", targets: ["SimmerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "SimmerCore"),
        .executableTarget(
            name: "simmer",
            dependencies: [
                "SimmerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SimmerCLI",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "simmer-app",
            dependencies: ["SimmerCore"],
            path: "Sources/SimmerApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SimmerCoreTests",
            dependencies: ["SimmerCore"]
        ),
        // Drives the BUILT binary under the seam variables — the acceptance suite.
        // Honours SIMMER_BIN, so it can gate any implementation of CONTRACTS.md.
        .testTarget(
            name: "SimmerAcceptanceTests",
            dependencies: ["simmer"]
        ),
    ]
)
