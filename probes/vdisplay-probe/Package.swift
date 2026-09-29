// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "vdisplay-probe",
    platforms: [.macOS(.v15)],
    targets: [
        // Hardware-independent logic: argument parsing, mode selection, FPS stats.
        .target(name: "ProbeCore"),
        .executableTarget(name: "vdisplay-probe", dependencies: ["ProbeCore"]),
        .testTarget(name: "ProbeCoreTests", dependencies: ["ProbeCore"]),
    ]
)
