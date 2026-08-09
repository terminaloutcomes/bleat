// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BleatCoreApp",
    platforms: [
        .iOS(.v26),
        .macCatalyst(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "BleatCore",
            targets: ["BleatCore"]
        ),
        .library(
            name: "BleatTranscription",
            targets: ["BleatTranscription"]
        ),
        .executable(
            name: "bleat-transcribe",
            targets: ["BleatTranscribeCLI"]
        ),
    ],
    targets: [
        .target(
            name: "BleatCore"
        ),
        .target(
            name: "BleatTranscription"
        ),
        .executableTarget(
            name: "BleatTranscribeCLI",
            dependencies: ["BleatTranscription"]
        ),
        .testTarget(
            name: "BleatCoreTests",
            dependencies: ["BleatCore"],
            resources: [
                .process("Fixtures")
            ]
        ),
        .testTarget(
            name: "BleatCoreLiveTests",
            dependencies: ["BleatCore"]
        ),
        .testTarget(
            name: "BleatTranscriptionTests",
            dependencies: ["BleatTranscription"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
