// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Bleat",
    platforms: [
        .iOS(.v17),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "BleatCore",
            targets: ["BleatCore"]
        ),
    ],
    targets: [
        .target(
            name: "BleatCore"
        ),
        .testTarget(
            name: "BleatCoreTests",
            dependencies: ["BleatCore"],
            resources: [
                .process("Fixtures"),
            ]
        ),
        .testTarget(
            name: "BleatCoreLiveTests",
            dependencies: ["BleatCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
