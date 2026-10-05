import Foundation
import Testing
@testable import DecProbeCore

@Test func clipSpecsCoverTheScene() {
    let clips = ClipSpec.standard(fullBitrateKbps: 60_000)
    #expect(clips.map(\.id) == ["full", "half", "half_right", "quarter"])
    let byId = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
    #expect(byId["full"]!.fileName == "full_2800x1840_8_60m.h265")
    #expect(byId["half"]!.fileName == "half_1400x1840_8_30m.h265")
    #expect(byId["half_right"]!.fileName == "half_right_1400x1840_8_30m.h265")
    #expect(byId["quarter"]!.fileName == "quarter_1400x920_8_15m.h265")
    // The two halves tile the full frame side by side.
    #expect(byId["half"]!.x == 0 && byId["half_right"]!.x == 1400)
    #expect(byId["half"]!.width + byId["half_right"]!.width == 2800)
    // Same bits per pixel.
    #expect(byId["full"]!.bitrateKbps == 60_000)
    #expect(byId["half"]!.bitrateKbps == 30_000)
    #expect(byId["quarter"]!.bitrateKbps == 15_000)
    for c in clips {
        #expect(c.width % 2 == 0 && c.height % 2 == 0)
        #expect(c.x + c.width <= ClipSpec.sceneWidth && c.y + c.height <= ClipSpec.sceneHeight)
    }
}

@Test func lengthPrefixedToAnnexB() {
    let hvcc: [UInt8] = [0, 0, 0, 3, 0x26, 0x01, 0xAF, 0, 0, 0, 2, 0x02, 0x01]
    #expect(AnnexB.fromLengthPrefixed(hvcc) == [0, 0, 0, 1, 0x26, 0x01, 0xAF, 0, 0, 0, 1, 0x02, 0x01])
    #expect(AnnexB.fromLengthPrefixed([0, 0, 0, 9, 1, 2]) == nil)       // length past the end
    #expect(AnnexB.fromLengthPrefixed([0, 3, 1, 2, 3], lengthSize: 2) == [0, 0, 0, 1, 1, 2, 3])
}

@Test func splitAndCountPictures() {
    // VPS(32) SPS(33) PPS(34) IDR_W_RADL(19, first slice) TRAIL_R(1, first slice) TRAIL_R(1, second slice) TRAIL_R(first)
    let vps: [UInt8] = [0x40, 0x01, 0x0C]
    let sps: [UInt8] = [0x42, 0x01, 0x01]
    let pps: [UInt8] = [0x44, 0x01, 0xC1]
    let idr: [UInt8] = [0x26, 0x01, 0xAF, 0x00, 0x00, 0x03]   // ends in 00 00 03 (emulation prevention)
    let p1: [UInt8] = [0x02, 0x01, 0xD0, 0x11]
    let p1b: [UInt8] = [0x02, 0x01, 0x40, 0x22]                // first_slice_segment_in_pic_flag = 0
    let p2: [UInt8] = [0x02, 0x01, 0x80]
    var stream = AnnexB.join([vps, sps, pps, idr, p1])
    stream += [0, 0, 1] + p1b                                  // 3-byte start code
    stream += AnnexB.join([p2])
    let nals = AnnexB.splitNALs(stream)
    #expect(nals.count == 7)
    #expect(nals.map(AnnexB.nalType) == [32, 33, 34, 19, 1, 1, 1])
    #expect(Array(nals[3]) == idr)
    #expect(AnnexB.pictureCount(stream) == 3)
    #expect(AnnexB.irapCount(stream) == 1)
}

@Test func argsParse() {
    let a = ProbeArgs(["--frames", "300", "--verify", "--out-dir", "/tmp/x", "--fps", "120"])
    #expect(a.int("frames", 600) == 300)
    #expect(a.int("fps", 60) == 120)
    #expect(a.string("out-dir", "") == "/tmp/x")
    #expect(a.flag("verify"))
    #expect(a.int("missing", 7) == 7)
}

@Test func variantNamesAndParsing() {
    func full(_ v: ClipVariant) -> ClipSpec {
        ClipSpec.standard(fullBitrateKbps: v.mbps * 1000, depth: v.depth, idrInterval: v.idrInterval)[0]
    }
    #expect(full(ClipVariant(depth: .pq10, mbps: 100)).fileName == "full_2800x1840_10pq_100m.h265")
    #expect(full(ClipVariant(depth: .sdr10, mbps: 60)).fileName == "full_2800x1840_10sdr_60m.h265")
    #expect(full(ClipVariant(depth: .b8, mbps: 60, idrInterval: 60)).fileName == "full_2800x1840_8_60m_idr60.h265")
    #expect(ClipVariant.parse("10pq@150") == ClipVariant(depth: .pq10, mbps: 150))
    #expect(ClipVariant.parse("8@60/idr60") == ClipVariant(depth: .b8, mbps: 60, idrInterval: 60))
    #expect(ClipVariant.parse("12@60") == nil)
    #expect(ClipVariant.parse("8@0") == nil)
    #expect(ClipVariant.parse("8@60/x") == nil)
    #expect(ClipVariant.parseList("8@60,10pq@80")?.count == 2)
    #expect(ClipVariant.parseList("8@60,bogus") == nil)
    #expect(ClipVariant.defaultSet.count == 10)
    #expect(Set(ClipVariant.defaultSet.map { full($0).fileName }).count == 10)
}

@Test func realizedBitrate() {
    // 600 frames at 120 fps = 5 s; 37.5 MB -> 60 Mbps.
    #expect(abs(Realized.mbps(bytes: 37_500_000, frames: 600, fps: 120) - 60) < 0.001)
    let dev = Realized.deviation(actualMbps: 48, targetKbps: 60_000)
    #expect(abs(dev + 0.2) < 1e-9)
    #expect(Realized.isOffTarget(dev))
    #expect(!Realized.isOffTarget(Realized.deviation(actualMbps: 66, targetKbps: 60_000)))
    #expect(Realized.isOffTarget(Realized.deviation(actualMbps: 70, targetKbps: 60_000)))
}

@Test func hdr10SEIPayloads() {
    let m = HDR10SEI.mdcv()
    #expect(m.count == 24)
    #expect(Array(m[0..<2]) == [0x33, 0xC2])                 // green x 0.265 / 0.00002 = 13250
    #expect(Array(m[16..<20]) == [0x00, 0x98, 0x96, 0x80])   // 1000 nits = 10_000_000
    #expect(Array(m[20..<24]) == [0, 0, 0, 1])               // 0.0001 nits
    #expect(HDR10SEI.cll() == [0x03, 0xE8, 0x01, 0x90])
}

/// Bit-level writer for building a synthetic SPS.
private struct BitWriter {
    var bytes: [UInt8] = []
    var n = 0
    mutating func u(_ bits: Int, _ v: Int) {
        for i in stride(from: bits - 1, through: 0, by: -1) {
            if n % 8 == 0 { bytes.append(0) }
            if (v >> i) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(0x80 >> (n % 8)) }
            n += 1
        }
    }
    mutating func ue(_ v: Int) {
        let x = v + 1
        let len = Int.bitWidth - x.leadingZeroBitCount
        u(len - 1, 0)
        u(len, x)
    }
}

private func makeSPS(profile: Int, bitDepth: Int, colour: (Int, Int, Int)?) -> ArraySlice<UInt8> {
    var w = BitWriter()
    w.u(4, 0); w.u(3, 0); w.u(1, 1)                       // vps id, max sub layers - 1, nesting
    w.u(2, 0); w.u(1, 0); w.u(5, profile)                 // profile space, tier, profile idc
    w.u(32, 0x6000_0000); w.u(4, 0b1001); w.u(32, 0); w.u(11, 0); w.u(1, 0)   // compat, flags, reserved, inbld
    w.u(8, 153)                                           // level
    w.ue(0); w.ue(1); w.ue(2800); w.ue(1840); w.u(1, 0)   // sps id, chroma 4:2:0, size, no conformance window
    w.ue(bitDepth - 8); w.ue(bitDepth - 8); w.ue(4)       // bit depths, poc lsb bits - 4
    w.u(1, 1); w.ue(2); w.ue(0); w.ue(0)                  // ordering info for 1 sub layer
    for v in [0, 2, 0, 3, 1, 1] { w.ue(v) }
    w.u(1, 1); w.u(1, 0); w.u(2, 0b11); w.u(1, 0)         // scaling lists enabled (default), amp, sao, no pcm
    w.ue(2)                                               // two short-term RPS
    w.ue(1); w.ue(0); w.ue(0); w.u(1, 1)                  // set 0: one negative picture, used
    w.u(1, 1); w.u(1, 0); w.ue(0)                         // set 1: predicted from set 0 (sign, abs_delta_rps - 1)
    w.u(1, 1)                                             //   ref entry 0 used
    w.u(1, 0); w.u(1, 1)                                  //   ref entry 1 unused but use_delta
    w.u(1, 0)                                             // no long-term refs
    w.u(2, 0b11)                                          // temporal mvp, strong intra smoothing
    if let c = colour {
        w.u(1, 1); w.u(1, 0); w.u(1, 0)                   // vui: no aspect ratio, no overscan
        w.u(1, 1); w.u(3, 5); w.u(1, 0); w.u(1, 1)        // video signal: format 5, limited range, colour description
        w.u(8, c.0); w.u(8, c.1); w.u(8, c.2)
    } else {
        w.u(1, 0)
    }
    w.u(1, 1)                                             // rbsp trailing bit
    return ([0x42, 0x01] + w.bytes)[...]
}

@Test func spsParserReadsDepthAndColour() {
    let pq = HevcSPS.parse(makeSPS(profile: 2, bitDepth: 10, colour: (9, 16, 9)))
    #expect(pq?.profileIdc == 2)
    #expect(pq?.bitDepthLuma == 10 && pq?.bitDepthChroma == 10)
    #expect(pq?.width == 2800 && pq?.height == 1840)
    #expect(pq?.colourPrimaries == 9 && pq?.transfer == 16 && pq?.matrix == 9)
    #expect(pq?.fullRange == false)
    let sdr = HevcSPS.parse(makeSPS(profile: 1, bitDepth: 8, colour: (1, 1, 1)))
    #expect(sdr?.profileIdc == 1 && sdr?.bitDepthLuma == 8)
    #expect(sdr?.colourPrimaries == 1 && sdr?.transfer == 1)
    let noVui = HevcSPS.parse(makeSPS(profile: 2, bitDepth: 10, colour: nil))
    #expect(noVui?.bitDepthLuma == 10 && noVui?.colourPrimaries == nil)
    #expect(HevcSPS.parse([0x42, 0x01, 0x01][...]) == nil)   // truncated
}

@Test func seiPayloadTypes() {
    let mdcv: [UInt8] = [0x4E, 0x01, 137, 24] + [UInt8](repeating: 0, count: 24) + [0x80]
    let cll: [UInt8] = [0x4E, 0x01, 144, 4, 3, 0xE8, 1, 0x90, 0x80]
    let nals = AnnexB.splitNALs(AnnexB.join([mdcv, cll]))
    #expect(HevcSPS.seiPayloadTypes(nals) == [137, 144])
}

@Test func hdr10SEINalUnitsAreWellFormed() {
    let nals = HDR10SEI.nalUnits()
    #expect(nals.count == 2)
    let stream = AnnexB.join(nals)
    let split = AnnexB.splitNALs(stream)
    #expect(split.count == 2)                                // no accidental start code inside a payload
    #expect(split.map(AnnexB.nalType) == [39, 39])
    #expect(HevcSPS.seiPayloadTypes(split) == [137, 144])
    #expect(AnnexB.escapeEmulation([0, 0, 0, 1, 0, 0, 3, 0, 0, 4]) == [0, 0, 3, 0, 1, 0, 0, 3, 3, 0, 0, 4])
    // Unescaping gives the payload back.
    #expect(Array(HevcSPS.rbsp(split[0]).dropFirst(2).prefix(24)) == HDR10SEI.mdcv())
}
