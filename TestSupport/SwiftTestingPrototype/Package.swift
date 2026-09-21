// swift-tools-version: 6.2
import PackageDescription

// Deliberately separate from the root test product: no XCTest test target is linked.
let package = Package(
    name: "SwiftTestingPrototype",
    platforms: [.macOS(.v26)],
    dependencies: [.package(name: "Bleat", path: "../..")],
    targets: [
        .testTarget(
            name: "PrototypeTests",
            dependencies: [.product(name: "BleatCore", package: "Bleat")],
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
