import Foundation
import Testing
@testable import DecProbeCore

@Test func clipSpecsCoverTheScene() {
    let clips = ClipSpec.standard(fullBitrateKbps: 60_000)
    #expect(clips.map(\.id) == ["full", "half", "half_right", "quarter"])
    let byId = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
    #expect(byId["full"]!.fileName == "full_2800x1840.h265")
    #expect(byId["half"]!.fileName == "half_1400x1840.h265")
    #expect(byId["half_right"]!.fileName == "half_right_1400x1840.h265")
    #expect(byId["quarter"]!.fileName == "quarter_1400x920.h265")
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
