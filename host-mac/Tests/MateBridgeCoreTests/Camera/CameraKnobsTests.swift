import Testing
@testable import MateBridgeCore

@Suite struct CameraKnobsTests {
    @Test func idleDefaultsAndBounds() {
        #expect(CameraKnobs.idleUs(nil) == 600_000_000)
        #expect(CameraKnobs.idleUs("") == 600_000_000)
        #expect(CameraKnobs.idleUs("abc") == 600_000_000)
        #expect(CameraKnobs.idleUs("5") == 600_000_000)  // below 10 s: refused
        #expect(CameraKnobs.idleUs("86401") == 600_000_000)
        #expect(CameraKnobs.idleUs("10") == 10_000_000)
        #expect(CameraKnobs.idleUs(" 120 ") == 120_000_000)
    }
}
