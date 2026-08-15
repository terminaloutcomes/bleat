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
    dependencies: [
        .package(
            url: "https://github.com/openid/AppAuth-iOS.git",
            exact: "2.0.0"
        ),
        .package(
            url:
                "https://github.com/open-telemetry/opentelemetry-swift-core.git",
            exact: "2.3.0"
        ),
    ],
    targets: [
        .target(
            name: "BleatCore",
            dependencies: [
                .product(name: "AppAuthCore", package: "AppAuth-iOS"),
                .product(
                    name: "OpenTelemetryApi",
                    package: "opentelemetry-swift-core"
                ),
                .product(
                    name: "OpenTelemetrySdk",
                    package: "opentelemetry-swift-core"
                ),
            ]
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
            dependencies: [
                "BleatCore",
                .product(
                    name: "OpenTelemetrySdk",
                    package: "opentelemetry-swift-core"
                ),
            ],
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
