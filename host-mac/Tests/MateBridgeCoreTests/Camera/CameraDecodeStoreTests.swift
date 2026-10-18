import Testing
@testable import MateBridgeCore

// Bounded frame storage in front of the camera decoder (T-357 r2).

private func drain(_ s: inout CameraDecodeStore<Int, String>) -> [String] {
    var out: [String] = []
    while let item = s.pop() {
        switch item {
        case .config(let c): out.append("c:\(c)")
        case .frame(let f): out.append("f:\(f)")
        }
    }
    return out
}

@Suite struct CameraDecodeStoreTests {
    @Test func holdsAtMostTwoFramesNewestKept() {
        var s = CameraDecodeStore<Int, String>()
        let first = s.push(frame: 1)  // the first push asks for the one drain
        #expect(first)
        for n in 2...4 {
            let again = s.push(frame: n)  // a stalled decoder never accumulates more
            #expect(!again)
        }
        #expect(s.frameCount == 2)
        #expect(drain(&s) == ["f:3", "f:4"])
    }

    @Test func oneDrainAtATimeAndANewOneAfterItEnded() {
        var s = CameraDecodeStore<Int, String>()
        let a = s.push(frame: 1)
        #expect(a)
        _ = drain(&s)
        let b = s.push(frame: 2)
        #expect(b)
    }

    @Test func configReplacesWaitingFramesAndOlderConfigsAndGoesFirst() {
        var s = CameraDecodeStore<Int, String>()
        _ = s.push(frame: 1)
        _ = s.push(config: "a")
        _ = s.push(config: "b")
        #expect(s.frameCount == 0)
        _ = s.push(frame: 2)
        #expect(drain(&s) == ["c:b", "f:2"])
    }

    @Test func removedFramesAreReportedOnceForTheGateToRetire() {
        var s = CameraDecodeStore<Int, String>()
        _ = s.push(frame: 1)
        _ = s.push(frame: 2)
        _ = s.push(frame: 3)  // evicts 1
        #expect(s.takeDropped() == 1)
        _ = s.push(config: "a")  // replaces 2 and 3
        #expect(s.takeDropped() == 2)
        _ = s.push(frame: 4)
        s.clearFrames()
        #expect(s.takeDropped() == 1)
        #expect(s.takeDropped() == 0)
        _ = s.pop()
        _ = s.pop()  // popped items are not "dropped": the decoder owns them
        #expect(s.takeDropped() == 0)
    }

    @Test func clearFramesKeepsTheConfigClearDropsAll() {
        var s = CameraDecodeStore<Int, String>()
        _ = s.push(config: "a")
        _ = s.push(frame: 1)
        s.clearFrames()
        #expect(s.hasConfig && s.frameCount == 0)
        s.clear()
        #expect(!s.hasConfig)
        #expect(drain(&s).isEmpty)
    }
}
