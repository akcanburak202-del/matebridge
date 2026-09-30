import Testing
@testable import MateBridgeCore

// GEO-*: normalized u16 to global points (PROTOCOL.md section 1). CLICK-*: multi-click counting.

/// The HiDPI virtual display at the main display's origin.
private func geometry(originX: Double = 0, originY: Double = 0, width: Double = 1400, height: Double = 920,
                      scale: Double = 2) -> DisplayGeometry {
    DisplayGeometry(originX: originX, originY: originY, widthPt: width, heightPt: height, scale: scale)!
}

@Suite("GEO: display geometry")
struct DisplayGeometryTests {
    @Test("GEO-1 corners map to origin and to the last addressable point (extent - 1/scale)")
    func geo1_corners() {
        let g = geometry()
        #expect(g.point(x: 0, y: 0) == DisplayPoint(x: 0, y: 0))
        #expect(g.point(x: 65535, y: 65535) == DisplayPoint(x: 1399.5, y: 919.5))
        #expect(g.point(x: 65535, y: 0) == DisplayPoint(x: 1399.5, y: 0))
        #expect(g.point(x: 0, y: 65535) == DisplayPoint(x: 0, y: 919.5))
    }

    @Test("GEO-2 the middle is linear in the normalized value")
    func geo2_linear() {
        let g = geometry()
        let p = g.point(x: 32768, y: 16384)
        #expect(abs(p.x - 32768.0 / 65535.0 * 1400) < 1e-9)
        #expect(abs(p.y - 16384.0 / 65535.0 * 920) < 1e-9)
    }

    @Test("GEO-3 a non-zero origin is added, never assumed to be (0, 0); negative origins work")
    func geo3_origin() {
        let offset = geometry(originX: 1920, originY: 30)
        #expect(offset.point(x: 0, y: 0) == DisplayPoint(x: 1920, y: 30))
        #expect(offset.point(x: 65535, y: 65535) == DisplayPoint(x: 1920 + 1399.5, y: 30 + 919.5))

        let left = geometry(originX: -1400, originY: -100)
        #expect(left.point(x: 0, y: 0) == DisplayPoint(x: -1400, y: -100))
        #expect(left.point(x: 65535, y: 65535) == DisplayPoint(x: -0.5, y: 819.5))
    }

    @Test("GEO-4 the upper bound follows the backing scale (1/scale points)")
    func geo4_scale() {
        #expect(geometry(scale: 1).point(x: 65535, y: 65535) == DisplayPoint(x: 1399, y: 919))
        let p = geometry(scale: 3).point(x: 65535, y: 65535)
        #expect(abs(p.x - (1400 - 1.0 / 3)) < 1e-9 && abs(p.y - (920 - 1.0 / 3)) < 1e-9)
    }

    @Test("GEO-5 every normalized value stays inside the display and the mapping never decreases")
    func geo5_monotonicInside() {
        let g = geometry(originX: -700, originY: 12)
        var lastX = -Double.infinity
        for v in stride(from: 0, through: 65535, by: 257) {
            let p = g.point(x: UInt16(v), y: UInt16(v))
            #expect(p.x >= -700 && p.x <= -700 + 1400 - 0.5)
            #expect(p.y >= 12 && p.y <= 12 + 920 - 0.5)
            #expect(p.x >= lastX)
            lastX = p.x
        }
    }

    @Test("GEO-6 a display that cannot be mapped onto is refused")
    func geo6_invalid() {
        #expect(DisplayGeometry(originX: 0, originY: 0, widthPt: 0, heightPt: 920, scale: 2) == nil)
        #expect(DisplayGeometry(originX: 0, originY: 0, widthPt: 1400, heightPt: -1, scale: 2) == nil)
        #expect(DisplayGeometry(originX: 0, originY: 0, widthPt: 1400, heightPt: 920, scale: 0) == nil)
        #expect(DisplayGeometry(originX: .nan, originY: 0, widthPt: 1400, heightPt: 920, scale: 2) == nil)
        #expect(DisplayGeometry(originX: 0, originY: 0, widthPt: .infinity, heightPt: 920, scale: 2) == nil)
        #expect(DisplayGeometry(originX: 0, originY: 0, widthPt: 1400, heightPt: 920, scale: .nan) == nil)
    }

    @Test("GEO-7 relative movement is clamped to the display; NaN goes to the origin")
    func geo7_moved() {
        let g = geometry(originX: 100, originY: 50)
        let mid = DisplayPoint(x: 800, y: 500)
        #expect(g.moved(mid, dx: 10, dy: -20) == DisplayPoint(x: 810, y: 480))
        #expect(g.moved(mid, dx: -5000, dy: -5000) == DisplayPoint(x: 100, y: 50))
        #expect(g.moved(mid, dx: 5000, dy: 5000) == DisplayPoint(x: 100 + 1399.5, y: 50 + 919.5))
        #expect(g.clamped(DisplayPoint(x: .nan, y: .infinity)) == DisplayPoint(x: 100, y: 50))
    }

    @Test("GEO-8 the center, and the PenPoint overload converts x and y")
    func geo8_centerAndPenPoint() {
        let g = geometry(originX: 100, originY: 50)
        #expect(g.center == DisplayPoint(x: 800, y: 510))
        #expect(g.point(penPt(65535, 0, 0)) == g.point(x: 65535, y: 0))
    }
}

@Suite("CLICK: multi-click counting")
struct ClickCounterTests {
    private let p = DisplayPoint(x: 100, y: 100)

    @Test("CLICK-1 presses close in time and place count up: 1, 2, 3")
    func click1_counts() {
        var c = ClickCounter()
        #expect(c.press(.left, at: p, now: 1_000_000) == 1)
        #expect(c.press(.left, at: p, now: 1_200_000) == 2)
        #expect(c.press(.left, at: p, now: 1_400_000) == 3)
    }

    @Test("CLICK-2 the interval is measured from the previous press, inclusive, and a late press starts over")
    func click2_interval() {
        var c = ClickCounter()
        #expect(c.press(.left, at: p, now: 0) == 1)
        #expect(c.press(.left, at: p, now: 500_000) == 2)  // exactly the interval
        #expect(c.press(.left, at: p, now: 1_000_001) == 1)  // 500_001 after the previous one
        #expect(c.press(.left, at: p, now: 1_500_001) == 2)
    }

    @Test("CLICK-3 the distance limit is inclusive; farther away starts over")
    func click3_distance() {
        var c = ClickCounter()
        #expect(c.press(.left, at: p, now: 0) == 1)
        #expect(c.press(.left, at: DisplayPoint(x: 103, y: 104), now: 100_000) == 2)  // 5 pt away
        #expect(c.press(.left, at: DisplayPoint(x: 103, y: 110.01), now: 200_000) == 1)
    }

    @Test("CLICK-4 another button starts over, and so does the history reset by a release-all")
    func click4_buttonAndReset() {
        var c = ClickCounter()
        #expect(c.press(.left, at: p, now: 0) == 1)
        #expect(c.press(.right, at: p, now: 100_000) == 1)
        #expect(c.press(.left, at: p, now: 200_000) == 1)
        #expect(c.press(.left, at: p, now: 300_000) == 2)
        c.reset()
        #expect(c.press(.left, at: p, now: 400_000) == 1)
    }

    @Test("CLICK-5 a clock that goes backwards never continues a sequence")
    func click5_backwardsClock() {
        var c = ClickCounter()
        #expect(c.press(.left, at: p, now: 5_000_000) == 1)
        #expect(c.press(.left, at: p, now: 4_900_000) == 1)
    }

    @Test("CLICK-6 the interval and distance are configurable")
    func click6_config() {
        var config = ClickCounter.Configuration()
        config.intervalUs = 100_000
        config.distancePt = 1
        var c = ClickCounter(configuration: config)
        #expect(c.press(.left, at: p, now: 0) == 1)
        #expect(c.press(.left, at: p, now: 100_001) == 1)
        #expect(c.press(.left, at: DisplayPoint(x: 100.5, y: 100), now: 150_000) == 2)
        #expect(c.press(.left, at: DisplayPoint(x: 102, y: 100), now: 160_000) == 1)
    }
}
