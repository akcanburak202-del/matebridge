import Testing
@testable import ProbeCore

@Test func parsesDefaultsAndFlags() throws {
    #expect(try ProbeOptions.parse([]) == ProbeOptions())
    let o = try ProbeOptions.parse(["--width", "2800", "--height", "1840", "--hidpi", "--seconds", "30"])
    #expect(o.width == 2800 && o.height == 1840 && o.hidpi && o.seconds == 30)
}

@Test func rejectsBadArguments() {
    #expect(throws: ProbeOptions.ParseError.unknownArgument("--x")) { try ProbeOptions.parse(["--x"]) }
    #expect(throws: ProbeOptions.ParseError.missingValue("--width")) { try ProbeOptions.parse(["--width"]) }
    #expect(throws: ProbeOptions.ParseError.invalidValue("--seconds", "abc")) { try ProbeOptions.parse(["--seconds", "abc"]) }
    #expect(throws: ProbeOptions.ParseError.invalidValue("--width", "0")) { try ProbeOptions.parse(["--width", "0"]) }
}

@Test func selectsHiDPIMode() {
    let modes = [
        DisplayModeInfo(width: 2800, height: 1840, pixelWidth: 2800, pixelHeight: 1840, refreshRate: 60),
        DisplayModeInfo(width: 1400, height: 920, pixelWidth: 2800, pixelHeight: 1840, refreshRate: 30),
        DisplayModeInfo(width: 1400, height: 920, pixelWidth: 2800, pixelHeight: 1840, refreshRate: 60),
    ]
    let hi = ModeSelector.select(from: modes, pixelWidth: 2800, pixelHeight: 1840, hidpi: true)
    #expect(hi?.width == 1400 && hi?.refreshRate == 60)
    let lo = ModeSelector.select(from: modes, pixelWidth: 2800, pixelHeight: 1840, hidpi: false)
    #expect(lo?.width == 2800)
    #expect(ModeSelector.select(from: modes, pixelWidth: 100, pixelHeight: 100, hidpi: true) == nil)
}

@Test func frameCounterWindows() {
    var c = FrameCounter()
    for _ in 0..<30 { c.record() }
    #expect(c.takeWindow() == 30)
    #expect(c.takeWindow() == 0)
    #expect(c.total == 30)
    #expect(FrameCounter.fps(frames: 30, seconds: 10) == 3.0)
    #expect(FrameCounter.fps(frames: 5, seconds: 0) == 0)
}
