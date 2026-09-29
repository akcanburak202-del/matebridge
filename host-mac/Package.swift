// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MateBridgeHost",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MateBridgeApp", targets: ["MateBridgeApp"]),
    ],
    targets: [
        .target(name: "MateBridgeCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "MateBridgeHost", dependencies: ["MateBridgeCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "MateBridgeApp",
            dependencies: ["MateBridgeCore", "MateBridgeHost"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "MateBridgeCoreTests", dependencies: ["MateBridgeCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
