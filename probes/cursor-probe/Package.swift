// swift-tools-version: 6.0
import PackageDescription

// T-271 local-cursor probe (macOS side). Not product code. See README.md.
let package = Package(
    name: "cursor-probe",
    platforms: [.macOS(.v15)],
    targets: [
        // Hardware-independent logic: arguments, change tracking, digests, statistics, record-line format.
        .target(name: "CursorProbeCore"),
        .executableTarget(name: "cursor-probe", dependencies: ["CursorProbeCore"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CursorProbeCoreTests", dependencies: ["CursorProbeCore"]),
    ]
)
