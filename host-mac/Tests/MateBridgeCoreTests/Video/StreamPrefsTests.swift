import XCTest
@testable import MateBridgeCore

final class StreamPrefsTests: XCTestCase {
    private let base = VideoSettings.tabletDefault

    func testNormalizedFpsAndScale() {
        XCTAssertEqual(StreamPrefs(fps: 120, scalePermille: 750).normalized, StreamPrefs(fps: 120, scalePermille: 750))
        XCTAssertEqual(StreamPrefs(fps: 144, scalePermille: 1000).normalized.fps, 144)
        for bad: UInt16 in [0, 30, 90, 119, 145, 240, 65535] {
            XCTAssertEqual(StreamPrefs(fps: bad, scalePermille: 800).normalized.fps, 60)
        }
        XCTAssertEqual(StreamPrefs(fps: 60, scalePermille: 0).normalized.scalePermille, 500)
        XCTAssertEqual(StreamPrefs(fps: 60, scalePermille: 499).normalized.scalePermille, 500)
        XCTAssertEqual(StreamPrefs(fps: 60, scalePermille: 1001).normalized.scalePermille, 1000)
        XCTAssertEqual(StreamPrefs(fps: 60, scalePermille: 65535).normalized.scalePermille, 1000)
    }

    func testEncodedSizeIsEvenAndKeepsAspect() {
        var s = base
        XCTAssertEqual(s.encodedWidthPx, 2800)
        XCTAssertEqual(s.encodedHeightPx, 1840)
        s.scalePermille = 750
        XCTAssertEqual([s.encodedWidthPx, s.encodedHeightPx], [2100, 1380])
        s.scalePermille = 500
        XCTAssertEqual([s.encodedWidthPx, s.encodedHeightPx], [1400, 920])
        for permille in stride(from: 500, through: 1000, by: 7) {
            s.scalePermille = permille
            XCTAssertEqual(s.encodedWidthPx % 2, 0, "width at \(permille)")
            XCTAssertEqual(s.encodedHeightPx % 2, 0, "height at \(permille)")
            let ratio = Double(s.encodedWidthPx) / Double(s.encodedHeightPx)
            XCTAssertEqual(ratio, 2800.0 / 1840.0, accuracy: 0.004, "aspect at \(permille)")
        }
        var odd = VideoSettings(widthPx: 1000, heightPx: 600, widthPt: 500, heightPt: 300, fps: 60, bitrateKbps: 1)
        odd.scalePermille = 501
        XCTAssertEqual(odd.encodedWidthPx % 2, 0)
        XCTAssertGreaterThanOrEqual(odd.encodedHeightPx, 2)
    }

    func testStreamConfigCarriesEncodedSizeButDisplayPointSize() {
        let cfg = base.applying(StreamPrefs(fps: 120, scalePermille: 750)).streamConfig(configID: 3)
        XCTAssertEqual([cfg.widthPx, cfg.heightPx], [2100, 1380])
        XCTAssertEqual([cfg.widthPt, cfg.heightPt], [1400, 920])
        XCTAssertEqual(cfg.fps, 120)
        XCTAssertEqual(cfg.configID, 3)
    }

    func testApplyingSetsFpsRefreshScaleAndBitrate() {
        let a = base.applying(StreamPrefs(fps: 144, scalePermille: 1000))
        XCTAssertEqual([a.fps, a.displayRefreshHz, a.scalePermille], [144, 144, 1000])
        XCTAssertEqual(a.bitrateKbps, 72_000)
        let b = base.applying(StreamPrefs(fps: 120, scalePermille: 750))
        XCTAssertEqual([b.fps, b.displayRefreshHz], [120, 120])
        XCTAssertEqual(b.bitrateKbps, 33_750)
        let c = base.applying(StreamPrefs(fps: 60, scalePermille: 1000), defaultRefreshHz: 120)
        XCTAssertEqual([c.fps, c.displayRefreshHz], [60, 120], "60 fps keeps the env/default refresh rate")
        XCTAssertEqual(c.bitrateKbps, 30_000)
        let d = base.applying(StreamPrefs(fps: 7, scalePermille: 10))
        XCTAssertEqual([d.fps, d.scalePermille], [60, 500])
        XCTAssertEqual(d.bitrateKbps, 20_000, "clamped to the 20 Mbps floor")
        XCTAssertEqual(VideoSettings.defaultBitrateKbps(fps: 144, scalePermille: 1000), 72_000)
        XCTAssertEqual(VideoSettings.defaultBitrateKbps(fps: 240, scalePermille: 1000), 80_000)
        XCTAssertTrue(a.sameDisplay(as: base))
        XCTAssertEqual([a.widthPx, a.heightPx, a.widthPt, a.heightPt], [2800, 1840, 1400, 920])
    }

    func testConfigIdIncrementsAndSkipsZero() {
        XCTAssertEqual(nextConfigID(after: 1), 2)
        XCTAssertEqual(nextConfigID(after: 65534), 65535)
        XCTAssertEqual(nextConfigID(after: 65535), 1)
    }

    func testGateAllowsFirstThenOnePerSecondLatestWins() {
        let sec: UInt64 = 1_000_000
        var g = StreamPrefsGate()
        let p1 = StreamPrefs(fps: 120, scalePermille: 1000)
        let p2 = StreamPrefs(fps: 144, scalePermille: 1000)
        let p3 = StreamPrefs(fps: 60, scalePermille: 500)
        XCTAssertEqual(g.offer(p1, now: 10 * sec), p1)
        g.markApplied(now: 10 * sec)
        XCTAssertNil(g.offer(p2, now: 10 * sec + 200_000))
        XCTAssertNil(g.offer(p3, now: 10 * sec + 400_000), "replaces the waiting request")
        XCTAssertNil(g.poll(now: 10 * sec + 999_999))
        XCTAssertEqual(g.poll(now: 11 * sec), p3)
        XCTAssertNil(g.poll(now: 12 * sec), "delivered once")
        XCTAssertFalse(g.hasPending)
    }

    func testGateRequestThatChangedNothingDoesNotConsumeTheBudget() {
        var g = StreamPrefsGate()
        let p = StreamPrefs(fps: 60, scalePermille: 1000)
        XCTAssertEqual(g.offer(p, now: 5), p)  // caller found no change and never calls markApplied
        XCTAssertEqual(g.offer(StreamPrefs(fps: 120, scalePermille: 1000), now: 6)?.fps, 120)
    }

    func testLeaseReconfigureKeepsDisplayForSameSize() {
        var l = DisplayLease()
        let dev = DeviceID(bytes: [UInt8](repeating: 1, count: 16))!
        _ = l.sessionStarted(device: dev, settings: base)
        let fast = base.applying(StreamPrefs(fps: 120, scalePermille: 750))
        XCTAssertEqual(l.reconfigure(settings: fast), [.reconfigure(fast)])
        XCTAssertTrue(l.reconfigure(settings: fast).isEmpty, "same settings: nothing")
        // The same device returning with its default settings gets a restart, not a new display.
        l.sessionEnded(now: 0)
        XCTAssertEqual(l.sessionStarted(device: dev, settings: base), [.reconfigure(base)])
        // A different display size still replaces the display.
        var other = base
        other.widthPx = 1920
        XCTAssertEqual(l.reconfigure(settings: other), [.teardown, .create(other)])
    }

    func testLeaseReconfigureWithoutSessionDoesNothing() {
        var l = DisplayLease()
        XCTAssertTrue(l.reconfigure(settings: base.applying(StreamPrefs(fps: 120, scalePermille: 1000))).isEmpty)
    }
}
