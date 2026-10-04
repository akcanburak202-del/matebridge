// swift-tools-version: 6.0
import PackageDescription

// T-230 colour-range bitstream probe (macOS side). Not product code. See README.md.
let package = Package(
    name: "color-range-probe",
    platforms: [.macOS(.v15)],
    targets: [
        // Hardware-independent logic: band pattern, band measurement, SPS VUI parser, configurations, arguments.
        .target(name: "ColorRangeProbeCore"),
        .executableTarget(name: "color-range-probe", dependencies: ["ColorRangeProbeCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ColorRangeProbeCoreTests", dependencies: ["ColorRangeProbeCore"]),
    ]
)
