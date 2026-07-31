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
        )
    ],
    targets: [
        .target(
            name: "BleatCore"
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
    ],
    swiftLanguageModes: [.v6]
)
