// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "obs-cam-probe",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "obs-cam-probe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
