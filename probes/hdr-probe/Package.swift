// swift-tools-version: 6.0
import PackageDescription

// T-226 HDR feasibility probe (macOS side). Not product code. See README.md for what each subcommand touches.
let package = Package(
    name: "hdr-probe",
    platforms: [.macOS("26.0")],
    targets: [
        // Hardware-independent logic: PQ/HLG maths, HDR10 metadata bytes, stats, argument parsing.
        .target(name: "HDRProbeCore"),
        .executableTarget(name: "hdr-probe", dependencies: ["HDRProbeCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HDRProbeCoreTests", dependencies: ["HDRProbeCore"]),
    ]
)
