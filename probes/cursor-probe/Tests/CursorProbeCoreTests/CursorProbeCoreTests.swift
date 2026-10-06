import XCTest
@testable import CursorProbeCore

final class OptionsTests: XCTestCase {
    func testDefaultsToOnce() throws {
        let o = try ProbeOptions.parse([]).get()
        XCTAssertEqual(o.mode, .once)
        XCTAssertEqual(o.iterations, 2000)
    }

    func testRecordParses() throws {
        let o = try ProbeOptions.parse(["record", "--seconds", "45", "--out", "/tmp/a", "--hz", "120",
                                        "--dump-dir", "/tmp/d", "--no-position", "--no-windowlist"]).get()
        XCTAssertEqual(o.mode, .record)
        XCTAssertEqual(o.seconds, 45)
        XCTAssertEqual(o.hz, 120)
        XCTAssertEqual(o.outPath, "/tmp/a")
        XCTAssertEqual(o.dumpDir, "/tmp/d")
        XCTAssertFalse(o.recordPosition)
        XCTAssertFalse(o.useWindowList)
    }

    func testErrors() {
        XCTAssertEqual(ProbeOptions.parse(["record"]), .failure(.missingOut))
        XCTAssertEqual(ProbeOptions.parse(["bogus"]), .failure(.unknownArgument("bogus")))
        XCTAssertEqual(ProbeOptions.parse(["record", "--hz"]), .failure(.missingValue("--hz")))
        XCTAssertEqual(ProbeOptions.parse(["record", "--hz", "0", "--out", "x"]), .failure(.badValue("--hz", "0")))
        XCTAssertEqual(ProbeOptions.parse(["--seconds", "-1"]), .failure(.badValue("--seconds", "-1")))
        XCTAssertEqual(ProbeOptions.parse(["--nope"]), .failure(.unknownArgument("--nope")))
    }
}

final class ChangeTrackerTests: XCTestCase {
    func testReportsOnlyChanges() {
        var t = ChangeTracker<Int>()
        XCTAssertTrue(t.update(1))
        XCTAssertFalse(t.update(1))
        XCTAssertTrue(t.update(2))
        XCTAssertTrue(t.update(1))
        XCTAssertEqual(t.changes, 3)
        XCTAssertEqual(t.last, 1)
    }

    func testOptionalValues() {
        var t = ChangeTracker<Bool?>()
        XCTAssertTrue(t.update(nil))
        XCTAssertFalse(t.update(nil))
        XCTAssertTrue(t.update(true))
    }
}

final class DigestTests: XCTestCase {
    func testKnownFNVVectors() {
        XCTAssertEqual(Digest.fnv1a64([UInt8]()), 0xcbf2_9ce4_8422_2325)
        XCTAssertEqual(Digest.fnv1a64(Array("a".utf8)), 0xaf63_dc4c_8601_ec8c)
        XCTAssertEqual(Digest.fnv1a64(Array("foobar".utf8)), 0x8594_4171_f739_67e8)
    }

    func testWordHashSeparatesAndIsStable() {
        var a = [UInt8](repeating: 0, count: 37)
        let h0 = a.withUnsafeBytes { Digest.wordHash64($0) }
        XCTAssertEqual(h0, a.withUnsafeBytes { Digest.wordHash64($0) })
        for i in [0, 7, 8, 36] { // word body and tail bytes both matter
            var b = a
            b[i] = 1
            XCTAssertNotEqual(b.withUnsafeBytes { Digest.wordHash64($0) }, h0, "byte \(i)")
        }
        a.append(0)
        XCTAssertNotEqual(a.withUnsafeBytes { Digest.wordHash64($0) }, h0, "length matters")
    }

    func testHexIsPadded() {
        XCTAssertEqual(Digest.hex(0xabc), "0000000000000abc")
        XCTAssertEqual(Digest.hex(UInt64.max), "ffffffffffffffff")
    }
}

final class StatsTests: XCTestCase {
    func testPercentiles() throws {
        let s = try XCTUnwrap(DurationStats(nanoseconds: (1...100).map { UInt64($0) * 1000 }))
        XCTAssertEqual(s.count, 100)
        XCTAssertEqual(s.minUs, 1)
        XCTAssertEqual(s.maxUs, 100)
        XCTAssertEqual(s.p50Us, 51, accuracy: 1)
        XCTAssertEqual(s.p99Us, 99, accuracy: 1)
        XCTAssertEqual(s.meanUs, 50.5, accuracy: 0.001)
        XCTAssertNil(DurationStats(nanoseconds: []))
    }

    func testFormat() {
        XCTAssertEqual(f(1.26), "1.3")
        XCTAssertEqual(f(2), "2.0")
        XCTAssertEqual(f(0.04), "0.0")
        XCTAssertEqual(f(12.34), "12.3")
    }
}

final class RecordFormatTests: XCTestCase {
    func testShapeLine() {
        let s = ShapeInfo(digest: 0x1234, pixelWidth: 32, pixelHeight: 48, pointWidth: 16, pointHeight: 24,
                          hotSpotX: 4, hotSpotY: 2.5, reps: ["32x48", "16x24"])
        XCTAssertEqual(s.scale, 2)
        XCTAssertEqual(s.dumpFileName, "cursor-0000000000001234-32x48-2.0x.png")
        XCTAssertEqual(RecordLine.shape(t: 1.5, source: "currentSystem", s),
                       "1.500 shape src=currentSystem id=0000000000001234 px=32x48 pt=16.0x24.0 scale=2.0 hot=4.0,2.5 reps=32x48|16x24")
    }

    func testTimestampAndOthers() {
        XCTAssertEqual(RecordLine.ts(0.007), "0.007")
        XCTAssertEqual(RecordLine.ts(12.34), "12.340")
        XCTAssertEqual(RecordLine.visible(t: 0, source: "cgcursor", nil), "0.000 visible src=cgcursor value=n/a")
        XCTAssertEqual(RecordLine.visible(t: 1, source: "cgcursor", false), "1.000 visible src=cgcursor value=0")
        XCTAssertEqual(RecordLine.position(t: 2, x: 10, y: 20.25), "2.000 pos x=10.0 y=20.3")
        XCTAssertEqual(RecordLine.shapeNil(t: 3, source: "current"), "3.000 shape src=current nil")
        XCTAssertEqual(RecordLine.windowCursor(t: 4, present: false, x: 0, y: 0, w: 0, h: 0, alpha: 0), "4.000 cursorwindow absent")
        XCTAssertEqual(RecordLine.windowCursor(t: 5, present: true, x: 10, y: 20, w: 9, h: 18, alpha: 1),
                       "5.000 cursorwindow present x=10.0 y=20.0 w=9.0 h=18.0 alpha=1.0")
    }
}
