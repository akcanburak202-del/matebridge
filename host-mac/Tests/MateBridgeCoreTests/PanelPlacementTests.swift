import CoreGraphics
import Testing
@testable import MateBridgeCore

@Suite struct PanelPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1400, height: 900)
    let frame = CGRect(x: 100, y: 100, width: 420, height: 240)

    @Test func noScreensIsOffscreen() {
        #expect(PanelPlacement.isOffscreen(frame: frame, screens: []))
    }
    @Test func insideIsVisible() {
        #expect(!PanelPlacement.isOffscreen(frame: frame, screens: [screen]))
    }
    @Test func disjointIsOffscreen() {
        let other = CGRect(x: 5000, y: 0, width: 1400, height: 900)
        #expect(PanelPlacement.isOffscreen(frame: frame, screens: [other]))
    }
    @Test func mostlyOutsideIsOffscreen() {
        let f = CGRect(x: -350, y: 100, width: 420, height: 240)
        #expect(PanelPlacement.isOffscreen(frame: f, screens: [screen]))
    }
    @Test func partlyOutsideStaysPut() {
        let f = CGRect(x: -100, y: 100, width: 420, height: 240)
        #expect(!PanelPlacement.isOffscreen(frame: f, screens: [screen]))
    }
    @Test func emptyFrameIsOffscreen() {
        #expect(PanelPlacement.isOffscreen(frame: .zero, screens: [screen]))
    }
}
