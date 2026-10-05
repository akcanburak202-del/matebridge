import Foundation
import Metal
import XCTest
@testable import MateBridgeCore

/// T-258 (decision 0034): the AVC444v2 layout (CPU reference, ported from the T-255 probe) and the Metal kernel against it.
final class PackedChromaLayoutTests: XCTestCase {
    private func randomBGRA(_ w: Int, _ h: Int, seed: UInt64) -> [UInt8] {
        var rng = SplitMix64(seed: seed)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<out.count { out[i] = i % 4 == 3 ? 255 : UInt8(truncatingIfNeeded: rng.next()) }
        return out
    }

    func testValidSizes() {
        XCTAssertTrue(AVC444v2.isValid(width: 2800, height: 1840))
        XCTAssertFalse(AVC444v2.isValid(width: 2802, height: 1840))
        XCTAssertFalse(AVC444v2.isValid(width: 2800, height: 1841))
        XCTAssertFalse(AVC444v2.isValid(width: 0, height: 2))
    }

    func testPackUnpackRoundTripIsExact() {
        let w = 32, h = 16
        let p = AVC444v2.planes444(bgra: randomBGRA(w, h, seed: 1), width: w, height: h, stride: w * 4)
        let (main, aux) = AVC444v2.pack(p)
        XCTAssertEqual(AVC444v2.unpack(main: main, aux: aux), p)
    }

    func testMainIsTheEvenEvenPictureAndAuxCarriesTheRest() {
        let w = 8, h = 4
        var p = Planes444(width: w, height: h)
        for i in 0..<(w * h) {
            p.y[i] = UInt8(i)
            p.cb[i] = UInt8(100 + i)
            p.cr[i] = UInt8(200 - i)
        }
        let (main, aux) = AVC444v2.pack(p)
        XCTAssertEqual(main.y, p.y)
        XCTAssertEqual(main.cb[0], p.cb[0])
        XCTAssertEqual(main.cb[1], p.cb[2])  // chroma sample (1, 0) = pixel (2, 0)
        XCTAssertEqual(main.cr[4], p.cr[2 * w])  // chroma sample (0, 1) = pixel (0, 2)
        XCTAssertEqual(aux.y[0], p.cb[1])  // odd columns of Cb, left half
        XCTAssertEqual(aux.y[4], p.cr[1])  // odd columns of Cr, right half (x = W/2)
        XCTAssertEqual(aux.cb[0], p.cb[w])  // (even column 0, odd row 1) of Cb
        XCTAssertEqual(aux.cr[0], p.cb[w + 2])  // column 2
        XCTAssertEqual(aux.cb[2], p.cr[w])  // right half (x = W/4) takes Cr
        XCTAssertEqual(aux.cr[2], p.cr[w + 2])
    }

    func testMetalKernelMatchesCPUReference() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("no Metal device")
        }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(source: PackedChromaKernel.metalSource, options: options)
        let fn = try XCTUnwrap(library.makeFunction(name: PackedChromaKernel.function))
        let pipeline = try device.makeComputePipelineState(function: fn)

        let w = 128, h = 64, cw = w / 2, ch = h / 2
        let bgra = randomBGRA(w, h, seed: 7)
        func tex(_ f: MTLPixelFormat, _ tw: Int, _ th: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: tw, height: th, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            return try XCTUnwrap(device.makeTexture(descriptor: d))
        }
        let src = try tex(.bgra8Unorm, w, h)
        bgra.withUnsafeBytes {
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        let mY = try tex(.r8Unorm, w, h), mC = try tex(.rg8Unorm, cw, ch)
        let aY = try tex(.r8Unorm, w, h), aC = try tex(.rg8Unorm, cw, ch)
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let e = try XCTUnwrap(cb.makeComputeCommandEncoder())
        e.setComputePipelineState(pipeline)
        for (i, t) in [src, mY, mC, aY, aC].enumerated() { e.setTexture(t, index: i) }
        e.dispatchThreads(MTLSize(width: cw, height: ch, depth: 1), threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        XCTAssertEqual(cb.status, .completed)

        func readY(_ t: MTLTexture) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: w * h)
            b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: w, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0) }
            return b
        }
        func readC(_ t: MTLTexture) -> (cb: [UInt8], cr: [UInt8]) {
            var b = [UInt8](repeating: 0, count: cw * ch * 2)
            b.withUnsafeMutableBytes { t.getBytes($0.baseAddress!, bytesPerRow: cw * 2, from: MTLRegionMake2D(0, 0, cw, ch), mipmapLevel: 0) }
            return ((0..<(cw * ch)).map { b[2 * $0] }, (0..<(cw * ch)).map { b[2 * $0 + 1] })
        }
        let (refMain, refAux) = AVC444v2.pack(AVC444v2.planes444(bgra: bgra, width: w, height: h, stride: w * 4))
        // The layout is exact; the colour maths (float division and rounding) may differ by one code on a rounding tie
        // between the GPU and the CPU, so the planes are compared to within 1 and the ties counted.
        func close(_ gpu: [UInt8], _ cpu: [UInt8], _ what: String) {
            XCTAssertEqual(gpu.count, cpu.count, what)
            let diffs = zip(gpu, cpu).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(diffs.max() ?? 0, 1, what)
            XCTAssertLessThanOrEqual(diffs.filter { $0 != 0 }.count, gpu.count / 500, what)
        }
        close(readY(mY), refMain.y, "main Y")
        close(readC(mC).cb, refMain.cb, "main Cb")
        close(readC(mC).cr, refMain.cr, "main Cr")
        close(readY(aY), refAux.y, "aux Y")
        close(readC(aC).cb, refAux.cb, "aux Cb")
        close(readC(aC).cr, refAux.cr, "aux Cr")
    }
}

private final class RecordingTransport: VideoTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [VideoFrame] = []
    private var ready: (@Sendable () -> Void)?
    var canSend: Bool { true }
    func setReadyHandler(_ handler: (@Sendable () -> Void)?) { lock.withLock { ready = handler } }
    func send(_ frame: VideoFrame, completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        lock.withLock { frames.append(frame) }
        completion(true)
        return true
    }
    var sent: [VideoFrame] { lock.withLock { frames } }
}

/// The packed sender (decision 0034): both streams on one connection, main first, `frame_seq` per stream, an auxiliary
/// frame only after the main frame it belongs to, and none whose main frame was never sent.
final class PackedSenderTests: XCTestCase {
    private func enc(_ t: UInt64, view: UInt8, key: Bool = false, config: Bool = false) -> EncodedVideoFrame {
        var f = EncodedVideoFrame(flags: config ? .codecConfig : (key ? .keyframe : []), captureTimeUs: t, data: [UInt8(t & 0xff)])
        f.view = view
        f.pairID = config ? 0 : t  // the tests use one number for the capture time and the submission
        return f
    }

    private func waitUntil(_ what: String, _ cond: () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        while !cond(), Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(cond(), what)
    }

    func testOrderViewsAndPerStreamSequence() async {
        let main = VideoFrameQueue(keyframeNeeded: {}), aux = VideoFrameQueue(keyframeNeeded: {})
        let t = RecordingTransport()
        let sender = VideoSender(transport: t, frames: main, auxFrames: aux, requestKeyframe: {})
        // Auxiliary output may arrive before the main frame it belongs to (it is held, not sent early).
        aux.push(enc(0, view: 1, config: true))
        aux.push(enc(100, view: 1, key: true))
        sender.start()
        await waitUntil("aux config goes at once") { t.sent.count == 1 }
        XCTAssertEqual(t.sent.map(\.view), [1])
        main.push(enc(0, view: 0, config: true))
        main.push(enc(100, view: 0, key: true))
        await waitUntil("main config, main 100, aux 100") { t.sent.count == 4 }
        let rest = t.sent.dropFirst()
        XCTAssertEqual(rest.map(\.view), [0, 0, 1])
        XCTAssertEqual(rest.map(\.captureTimeUs), [0, 100, 100])
        // frame_seq counts per stream: aux config = 0, aux 100 = 1; main config = 0, main 100 = 1.
        XCTAssertEqual(t.sent.map(\.frameSeq), [0, 0, 1, 1])
        await sender.stop()
    }

    func testAuxOfALostMainFrameIsDroppedAndAKeyframeRequested() async {
        let main = VideoFrameQueue(keyframeNeeded: {}), aux = VideoFrameQueue(keyframeNeeded: {})
        let t = RecordingTransport()
        let asked = ActivityCounter()
        let sender = VideoSender(transport: t, frames: main, auxFrames: aux, requestKeyframe: {},
                                 requestAuxKeyframe: { asked.increment() })
        sender.start()
        main.push(enc(100, view: 0, key: true))
        await waitUntil("main 100") { t.sent.count == 1 }
        main.push(enc(130, view: 0))
        await waitUntil("main 130") { t.sent.count == 2 }
        aux.push(enc(115, view: 1))  // its main frame (115) never went out
        await waitUntil("aux 115 dropped") { sender.currentCounters.auxDropped == 1 }
        XCTAssertEqual(asked.value, 1)
        XCTAssertEqual(t.sent.map(\.view), [0, 0])
        aux.push(enc(130, view: 1))  // refused: the auxiliary chain awaits a keyframe
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(t.sent.count, 2)
        aux.push(enc(160, view: 1, key: true))
        main.push(enc(160, view: 0))
        await waitUntil("main 160 and aux 160") { t.sent.count == 4 }
        XCTAssertEqual(t.sent.suffix(2).map(\.view), [0, 1])
        await sender.stop()
    }
}

private final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

final class PackedChromaFlowTests: XCTestCase {
    func testMainFirstThenAuxOfASentMainFrame() {
        var a = PackedSendArbiter()
        XCTAssertEqual(a.pick(mainAvailable: true, aux: (100, false)), .main)
        // The auxiliary frame of capture 100 waits until main 100 was sent.
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (100, false)), .wait)
        a.mainSent(pairID: 100)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (100, false)), .aux)
        // A newer main frame still goes before any auxiliary one.
        XCTAssertEqual(a.pick(mainAvailable: true, aux: (100, false)), .main)
    }

    func testRefinementTimestampsDoNotMakeARealAuxFrameLookLost() {
        // Pair ids rise with submission order. A refinement pair (id 11) has a synthetic, later timestamp than the real
        // capture pair (id 12) submitted after it: matching is by id, so the real aux frame is not dropped.
        var a = PackedSendArbiter()
        a.mainSent(pairID: 11)
        a.mainSent(pairID: 12)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (11, false)), .aux)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (12, false)), .aux)
    }

    func testAuxConfigIsNeverHeld() {
        let a = PackedSendArbiter()
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (0, true)), .aux)
    }

    func testAuxWhoseMainFrameWasLostIsDropped() {
        var a = PackedSendArbiter()
        a.mainSent(pairID: 100)
        a.mainSent(pairID: 130)  // the main frame of submission 115 never went out
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (115, false)), .dropAux)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (130, false)), .aux)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: nil), .wait)
    }

    func testMemoryIsBounded() {
        var a = PackedSendArbiter()
        for i in 1...20 { a.mainSent(pairID: UInt64(i)) }
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (20, false)), .aux)
        XCTAssertEqual(a.pick(mainAvailable: false, aux: (3, false)), .dropAux)  // forgotten, older than the newest
    }

    func testMonitorFallsBackAfterThreeBadWindows() {
        var m = PackedChromaMonitor()
        for window in 1...3 {
            for i in 0..<60 { m.recordOffered(); if i < 6 { m.recordLost() } }  // 10 %
            let d = m.closeWindow()
            if window < 3 { XCTAssertNil(d) } else { XCTAssertEqual(d, .fallback(reason: "aux_loss")) }
        }
        // Once only.
        for i in 0..<60 { m.recordOffered(); if i < 30 { m.recordLost() } }
        XCTAssertNil(m.closeWindow())
    }

    func testMonitorIgnoresShortWindowsAndGoodWindowsReset() {
        var m = PackedChromaMonitor()
        for _ in 0..<5 {  // too few frames to judge
            for _ in 0..<5 { m.recordOffered(); m.recordLost() }
            XCTAssertNil(m.closeWindow())
        }
        for _ in 0..<2 {
            for i in 0..<60 { m.recordOffered(); if i < 6 { m.recordLost() } }
            XCTAssertNil(m.closeWindow())
        }
        for _ in 0..<60 { m.recordOffered() }  // a good window resets the run
        XCTAssertNil(m.closeWindow())
        for i in 0..<60 { m.recordOffered(); if i < 6 { m.recordLost() } }
        XCTAssertNil(m.closeWindow())
    }

    func testFivePercentExactlyIsNotBad() {
        var m = PackedChromaMonitor()
        for _ in 0..<3 {
            for i in 0..<60 { m.recordOffered(); if i < 3 { m.recordLost() } }  // exactly 5 %
            XCTAssertNil(m.closeWindow())
        }
    }

    func testHardErrorFallsBackOnce() {
        var m = PackedChromaMonitor()
        XCTAssertEqual(m.recordError("aux_encode_errors"), .fallback(reason: "aux_encode_errors"))
        XCTAssertNil(m.recordError("again"))
        XCTAssertNil(m.closeWindow())
    }

    func testRefineReadinessNeedsTheAuxQueueOnlyWhenPacked() {
        XCTAssertTrue(RefineReadiness.ready(mainReady: true, auxReady: false, packed: false), "idle aux queue must not block")
        XCTAssertFalse(RefineReadiness.ready(mainReady: true, auxReady: false, packed: true))
        XCTAssertTrue(RefineReadiness.ready(mainReady: true, auxReady: true, packed: true))
        XCTAssertFalse(RefineReadiness.ready(mainReady: false, auxReady: true, packed: false))
    }

    func testStatsWindowLine() {
        var w = PackedChromaStatsWindow(startUs: 0)
        w.recordPack(wallUs: 900, gpuUs: 700)
        w.recordMain(bytes: 1000)
        w.recordAux(bytes: 400, encodeUs: 5000)
        w.recordAuxLost()
        XCTAssertNil(w.take(nowUs: 9_999_999))
        let line = w.take(nowUs: 10_000_000)
        XCTAssertEqual(line, "mode=packed444 frames=1 aux_frames=1 pack_ms_p50_95=0.90/0.90 pack_gpu_ms_p50_95=0.70/0.70 "
                       + "aux_enc_ms_p50_95=5.00/5.00 aux_main_bytes=0.40 aux_lost=1 pack_fail=0")
    }

    // MARK: Queue helpers

    private func frame(_ t: UInt64, key: Bool = false, config: Bool = false) -> EncodedVideoFrame {
        var f = EncodedVideoFrame(flags: config ? .codecConfig : (key ? .keyframe : []), captureTimeUs: t, data: [1])
        f.view = 1
        return f
    }

    func testTryPopWhereDecidesUnderTheLock() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(frame(10, key: true))
        XCTAssertNil(q.tryPop(where: { $0.captureTimeUs == 99 }))
        XCTAssertEqual(q.tryPop(where: { $0.captureTimeUs == 10 })?.captureTimeUs, 10)
        XCTAssertFalse(q.hasFrames)
    }

    func testBreakChainRefusesDeltasUntilAKeyframe() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(frame(1, key: true))
        q.push(frame(2))
        q.breakChain()
        XCTAssertEqual(q.tryPop()?.captureTimeUs, 1)  // the keyframe survives, the delta was purged
        XCTAssertNil(q.tryPop())
        q.push(frame(3))  // refused
        XCTAssertNil(q.tryPop())
        q.push(frame(4, key: true))
        XCTAssertEqual(q.tryPop()?.captureTimeUs, 4)
    }

    func testDiscardedCountIncludesRefusedAndPurgedFrames() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        q.push(frame(1, key: true))
        q.push(frame(2))
        q.breakChain()  // purges the delta
        XCTAssertEqual(q.discardedCount, 1)
        q.push(frame(3))  // refused while awaiting a keyframe
        q.push(frame(4))
        XCTAssertEqual(q.discardedCount, 3)
        XCTAssertEqual(q.droppedCount, 0, "the cadence counter is unchanged")
    }

    func testActivityHandlerFiresOnPushAndFinish() {
        let q = VideoFrameQueue(keyframeNeeded: {})
        let n = ActivityCounter()
        q.setActivityHandler { n.increment() }
        q.push(frame(1))
        q.finish()
        XCTAssertEqual(n.value, 2)
        XCTAssertTrue(q.isFinished)
    }
}
