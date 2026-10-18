import Testing
@testable import MateBridgeCore

@Suite struct CameraKnobsTests {
    @Test func probeIntervalDefaultsAndBounds() {
        #expect(CameraKnobs.probeIntervalUs(nil) == 15_000_000)
        #expect(CameraKnobs.probeIntervalUs("") == 15_000_000)
        #expect(CameraKnobs.probeIntervalUs("abc") == 15_000_000)
        #expect(CameraKnobs.probeIntervalUs("1") == 15_000_000)  // below 3 s: refused
        #expect(CameraKnobs.probeIntervalUs("301") == 15_000_000)
        #expect(CameraKnobs.probeIntervalUs("3") == 3_000_000)
        #expect(CameraKnobs.probeIntervalUs(" 30 ") == 30_000_000)
        #expect(CameraKnobs.probeIntervalUs("7.5") == 7_500_000)
    }
}
