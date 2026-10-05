// swift-tools-version: 6.0
import PackageDescription

// T-255 4:4:4-in-4:2:0 packing probe (macOS side, AVC444v2 layout). Not product code. See README.md.
let package = Package(
    name: "yuv444-probe",
    platforms: [.macOS("26.0")],
    targets: [
        // Hardware-independent logic: the AVC444v2 layout (CPU reference pack/unpack), BT.709 maths, PSNR, stats, args,
        // the Metal kernel source, scene phases, and a copy of the 0033 sharp-YUV CPU reference.
        .target(name: "YUV444Core"),
        // The Metal packer (BGRA -> main + aux 420f IOSurface buffers). Needs a GPU; its tests skip without one.
        .target(name: "YUV444GPU", dependencies: ["YUV444Core"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "yuv444-probe", dependencies: ["YUV444Core", "YUV444GPU"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "YUV444Tests", dependencies: ["YUV444Core", "YUV444GPU"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
