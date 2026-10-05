// swift-tools-version: 6.0
import PackageDescription

// T-248 decoder concurrency probe (macOS side): makes the HEVC test clips for the Android probe. Not product code.
let package = Package(
    name: "decoder-concurrency-probe",
    platforms: [.macOS("26.0")],
    targets: [
        // Hardware-independent logic: clip specs, Annex-B conversion and access-unit counting, argument parsing.
        .target(name: "DecProbeCore"),
        .executableTarget(name: "decprobe-clips", dependencies: ["DecProbeCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "DecProbeCoreTests", dependencies: ["DecProbeCore"]),
    ]
)
