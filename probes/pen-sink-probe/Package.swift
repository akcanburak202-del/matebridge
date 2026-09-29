// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "pen-sink-probe",
    platforms: [.macOS(.v15)],
    targets: [
        // Event-field mapping + injector; intended to move into MateBridgeHost later.
        .target(name: "PenInjection"),
        .executableTarget(name: "pen-sink-probe", dependencies: ["PenInjection"]),
        .testTarget(name: "PenInjectionTests", dependencies: ["PenInjection"]),
    ]
)
