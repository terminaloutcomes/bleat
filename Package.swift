// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BleatCoreApp",
    platforms: [
        .iOS(.v26),
        .macOS(.v26),
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
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/open-telemetry/opentelemetry-swift.git",
            exact: "2.4.1"
        ),
        .package(
            url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
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
                .product(
                    name: "OpenTelemetryProtocolExporterHTTP",
                    package: "opentelemetry-swift"
                ),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
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
            dependencies: [
                "BleatCore",
                .product(
                    name: "OpenTelemetryProtocolExporterHTTP",
                    package: "opentelemetry-swift"
                ),
            ]
        ),
        .testTarget(
            name: "BleatTranscriptionTests",
            dependencies: ["BleatTranscription"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
