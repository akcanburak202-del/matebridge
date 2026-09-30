import Testing
@testable import MateBridgeCore

@Suite("TABID: tablet identity")
struct TabletIdentityTests {
    @Test("TABID-1 pen and eraser differ and both are a Stylus by Qt's rule")
    func pointerTypes() {
        let pen = TabletIdentity.vendorPointerType(.pen)
        let eraser = TabletIdentity.vendorPointerType(.eraser)
        #expect(pen == 0x0802)
        #expect(eraser == 0x080A)
        #expect(pen != eraser)
        #expect(TabletIdentity.qtTreatsAsStylus(pen))
        #expect(TabletIdentity.qtTreatsAsStylus(eraser))
        #expect(!TabletIdentity.qtTreatsAsStylus(0))
    }

    @Test("TABID-2 unique ID is nonzero and fixed")
    func uniqueID() {
        #expect(TabletIdentity.vendorUniqueID != 0)
        #expect(TabletIdentity.vendorUniqueID == 0x4D42_5045_4E)
    }
}
