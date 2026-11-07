// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DogSC",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RecorderCore", targets: ["RecorderCore"]),
        .executable(name: "DogSC", targets: ["DogSCApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/sparkle-project/Sparkle",
            exact: "2.9.4"
        ),
    ],
    targets: [
        .target(
            name: "RecorderCore",
            path: "Sources/RecorderCore"
        ),
        .executableTarget(
            name: "DogSCApp",
            dependencies: [
                "RecorderCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/DogSCApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-rpath",
                    "-Xlinker",
                    "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ],
    // Intel / Swift 6.1 compatibility: the sources target Swift 6.2 semantics
    // (isolated conformances, `sending` inference for non-sendable values).
    // The Swift 6.1 toolchain in Command Line Tools rejects those constructs,
    // so the local Intel build runs in Swift 5 language mode with complete
    // concurrency checking: the same checks are reported as warnings instead
    // of errors. Runtime behaviour is unchanged.
    // Set DOGSC_SWIFT6_MODE=1 only when building with Xcode 26 (Swift 6.2).
    swiftLanguageModes: [.v5]
)
