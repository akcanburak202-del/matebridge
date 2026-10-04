import Foundation
import Testing
@testable import HDRProbeCore

@Test func pqKnownPoints() {
    #expect(abs(PQ.encode(nits: 0)) < 1e-6)
    #expect(abs(PQ.encode(nits: 10_000) - 1) < 1e-9)
    // Reference values (BT.2100 / ITU-R BT.2408): 100 nits ~ 0.508, 203 nits ~ 0.58, 1000 nits ~ 0.752.
    #expect(abs(PQ.encode(nits: 100) - 0.5081) < 0.001)
    #expect(abs(PQ.encode(nits: 203) - 0.5806) < 0.001)
    #expect(abs(PQ.encode(nits: 1000) - 0.7518) < 0.001)
}

@Test func pqRoundTrip() {
    for nits in [0.1, 1.0, 50, 203, 500, 1000, 4000] {
        #expect(abs(PQ.decode(PQ.encode(nits: nits)) - nits) / nits < 1e-6)
    }
}

@Test func hlgKnownPoints() {
    #expect(abs(HLG.oetf(1.0 / 12) - 0.5) < 1e-9)
    #expect(abs(HLG.oetf(1) - 1) < 1e-6)
}

@Test func lumaCodes() {
    #expect(Luma10.videoRange(0) == 64)
    #expect(Luma10.videoRange(1) == 940)
    #expect(abs(Luma10.signal(videoRange: 940) - 1) < 1e-12)
}

@Test func mdcvLayout() {
    let d = HDR10Static.p3D65_1000.mdcvSEI()
    #expect(d.count == 24)
    // Green first: x 0.265 / 0.00002 = 13250 = 0x33C2.
    #expect(Array(d.prefix(2)) == [0x33, 0xC2])
    // Max luminance 1000 cd/m² = 10_000_000 (0x00989680) in 0.0001 units, bytes 16...19.
    #expect(Array(d[16..<20]) == [0x00, 0x98, 0x96, 0x80])
    #expect(Array(d[20..<24]) == [0x00, 0x00, 0x00, 0x01])
}

@Test func cllLayout() {
    #expect(Array(HDR10Static.p3D65_1000.cllSEI()) == [0x03, 0xE8, 0x01, 0x90])
}

@Test func percentiles() {
    let v = (1...100).map(Double.init)
    #expect(Stats.percentile(v, 50) == 50)
    #expect(Stats.percentile(v, 99) == 99)
    #expect(Stats.percentile([], 50) == 0)
}

@Test func argsParsing() {
    let a = ProbeArgs(["vd", "--tf", "1", "--reference", "--size", "1920x1080"])
    #expect(a.command == "vd")
    #expect(a.int("tf", 0) == 1)
    #expect(a.flag("reference"))
    #expect(a.size("size", (0, 0)) == (1920, 1080))
    #expect(a.int("missing", 7) == 7)
    #expect(ProbeArgs([]).command == "help")
}
