// obs-cam-probe: write a moving test pattern into the OBS Virtual Camera sink stream.
// API order is independently written from the public CoreMediaIO API; no OBS code is copied.
import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((msg + "\n").utf8))
    exit(code)
}

func st(_ s: OSStatus) -> String {
    let u = UInt32(bitPattern: s)
    let b = [24, 16, 8, 0].map { UInt8((u >> UInt32($0)) & 0xff) }
    if b.allSatisfy({ $0 >= 32 && $0 < 127 }) { return "\(s) '\(String(decoding: b, as: UTF8.self))'" }
    return "\(s)"
}

func addr(_ sel: Int, _ scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(sel),
                              mScope: CMIOObjectPropertyScope(scope),
                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
}

func ids(_ obj: CMIOObjectID, _ sel: Int) -> [CMIOObjectID] {
    var a = addr(sel)
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(obj, &a, 0, nil, &size) == 0, size > 0 else { return [] }
    var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, &out) == 0 else { return [] }
    return out
}

func string(_ obj: CMIOObjectID, _ sel: Int) -> String? {
    var a = addr(sel)
    let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var used: UInt32 = 0
    var s: Unmanaged<CFString>?
    let r = withUnsafeMutablePointer(to: &s) {
        CMIOObjectGetPropertyData(obj, &a, 0, nil, size, &used, $0)
    }
    guard r == 0, let s else { return nil }
    return s.takeRetainedValue() as String
}

func uint32(_ obj: CMIOObjectID, _ sel: Int) -> UInt32? {
    var a = addr(sel)
    var v: UInt32 = 0
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(obj, &a, 0, nil, 4, &used, &v) == 0 else { return nil }
    return v
}

struct Device { let id: CMIOObjectID; let name: String; let uid: String; let streams: [CMIOStreamID] }

func devices() -> [Device] {
    ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices).map {
        Device(id: $0,
               name: string($0, kCMIOObjectPropertyName) ?? "?",
               uid: string($0, kCMIODevicePropertyDeviceUID) ?? "?",
               streams: ids($0, kCMIODevicePropertyStreams))
    }
}

/// kCMIOStreamPropertyDirection: 0 = source (device -> client), 1 = sink (client -> device).
func direction(_ s: CMIOStreamID) -> UInt32? { uint32(s, kCMIOStreamPropertyDirection) }

func obsUUID() -> String? {
    let p = "/Applications/OBS.app/Contents/PlugIns/mac-virtualcam.plugin/Contents/Info.plist"
    if let d = NSDictionary(contentsOfFile: p), let u = d["OBSCameraDeviceUUID"] as? String { return u }
    return nil
}

func findOBS(_ devs: [Device]) -> Device? {
    if let u = obsUUID()?.uppercased(), let d = devs.first(where: { $0.uid.uppercased() == u }) { return d }
    return devs.first { $0.name == "OBS Virtual Camera" }
}

func listDevices() {
    let devs = devices()
    print("OBS UUID (plist): \(obsUUID() ?? "not found (OBS.app missing?)")")
    print("\(devs.count) CMIO device(s)")
    for d in devs {
        print("- \(d.name)  uid=\(d.uid)  id=\(d.id)  streams=\(d.streams.count)")
        for (i, s) in d.streams.enumerated() {
            let dir = direction(s).map { $0 == 1 ? "sink(1)" : "source(\($0))" } ?? "dir=?"
            print("    [\(i)] stream \(s) \(dir)")
        }
    }
    if let o = findOBS(devs) {
        print("OBS Virtual Camera: FOUND (device \(o.id))")
    } else {
        print("OBS Virtual Camera: NOT FOUND. Is OBS installed, the camera extension approved in System Settings, and the virtual camera started once?")
    }
}

// MARK: - pattern

let bars: [(UInt8, UInt8, UInt8)] = [(255,255,255),(255,255,0),(0,255,255),(0,255,0),(255,0,255),(255,0,0),(0,0,255),(0,0,0)] // R,G,B
let digits: [[UInt8]] = [ // 3x5 glyphs, row bitmasks
    [7,5,5,5,7],[2,6,2,2,7],[7,1,7,4,7],[7,1,7,1,7],[5,5,7,1,1],[7,4,7,1,7],[7,4,7,5,7],[7,1,1,1,1],[7,5,7,5,7],[7,5,7,1,7]]

func draw(_ pb: CVPixelBuffer, frame: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
    func px(_ x: Int, _ y: Int, _ c: (UInt8, UInt8, UInt8)) {
        let o = y * bpr + x * 4
        base[o] = c.2; base[o+1] = c.1; base[o+2] = c.0; base[o+3] = 255
    }
    for y in 0..<h { for x in 0..<w { px(x, y, bars[x * bars.count / w]) } }
    let bs = h / 5
    let bx = (frame * 8) % max(1, w - bs)
    let by = h / 2 - bs / 2 + Int(Double(h / 6) * sin(Double(frame) / 15))
    for y in max(0, by)..<min(h, by + bs) { for x in bx..<min(w, bx + bs) { px(x, y, (255, 128, 0)) } }
    let sc = max(2, h / 60)
    var cx = sc * 2
    for ch in String(frame % 100000) {
        let g = digits[Int(ch.wholeNumberValue ?? 0)]
        for r in 0..<5 {
            for c in 0..<3 where g[r] & (4 >> UInt8(c)) != 0 {
                for yy in 0..<sc {
                    for xx in 0..<sc {
                        let X = cx + c * sc + xx, Y = sc * 2 + r * sc + yy
                        if X < w && Y < h { px(X, Y, (255, 255, 255)) }
                    }
                }
            }
        }
        cx += 4 * sc
    }
}

nonisolated(unsafe) var stopFlag: Int32 = 0

func runPattern(seconds: Double, width: Int, height: Int, fps: Int) {
    let devs = devices()
    guard let dev = findOBS(devs) else {
        fail("OBS Virtual Camera device not found. Is OBS installed, the camera extension approved, and the virtual camera started once? (run --list)", 2)
    }
    var sink: CMIOStreamID?
    for s in dev.streams where direction(s) == 1 { sink = s }
    if sink == nil, dev.streams.count >= 2 { sink = dev.streams[1] } // OBS plugin uses index 1
    guard let sinkID = sink else {
        fail("No sink stream on '\(dev.name)' (\(dev.streams.count) stream(s)). Has the extension been started (virtual camera started once in OBS)?", 3)
    }

    var queue: Unmanaged<CMSimpleQueue>?
    var r = CMIOStreamCopyBufferQueue(sinkID, { _, _, _ in }, nil, &queue)
    guard r == 0, let q = queue?.takeRetainedValue() else { fail("CMIOStreamCopyBufferQueue failed: \(st(r))", 4) }

    var fdOpt: CMFormatDescription?
    r = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: Int32(width), height: Int32(height), extensions: nil, formatDescriptionOut: &fdOpt)
    guard r == 0, let fd = fdOpt else { fail("CMVideoFormatDescriptionCreate failed: \(st(r))", 5) }

    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                  kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                  kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
    var poolOpt: CVPixelBufferPool?
    let cr = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &poolOpt)
    guard cr == kCVReturnSuccess, let pool = poolOpt else { fail("CVPixelBufferPoolCreate failed: \(cr)", 6) }

    r = CMIODeviceStartStream(dev.id, sinkID)
    guard r == 0 else { fail("CMIODeviceStartStream failed: \(st(r)) (permission or extension not running?)", 7) }
    print("sink stream \(sinkID) of '\(dev.name)' started; \(width)x\(height) @ \(fps) fps for \(seconds) s")

    signal(SIGINT) { _ in stopFlag = 1 }
    signal(SIGTERM) { _ in stopFlag = 1 }

    let start = DispatchTime.now().uptimeNanoseconds
    let period = UInt64(1_000_000_000 / fps)
    var frame = 0, enqueued = 0, dropped = 0
    while stopFlag == 0 {
        let now = DispatchTime.now().uptimeNanoseconds
        if Double(now - start) / 1e9 >= seconds { break }
        var pbOpt: CVPixelBuffer?
        if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt) == kCVReturnSuccess, let pb = pbOpt {
            draw(pb, frame: frame)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(fps)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: 1_000_000_000),
                                            decodeTimeStamp: .invalid)
            var sbOpt: CMSampleBuffer?
            let sr = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb,
                                                              formatDescription: fd, sampleTiming: &timing, sampleBufferOut: &sbOpt)
            if sr == 0, let sb = sbOpt {
                // The queue takes ownership of one retain on success.
                let ref = Unmanaged.passRetained(sb)
                if CMSimpleQueueEnqueue(q, element: ref.toOpaque()) == 0 { enqueued += 1 } else { dropped += 1; ref.release() }
            }
        }
        frame += 1
        if frame % fps == 0 { print("t=\(frame / fps)s enqueued=\(enqueued) dropped(queue full)=\(dropped)") }
        let next = start + UInt64(frame) * period
        let n2 = DispatchTime.now().uptimeNanoseconds
        if next > n2 { usleep(UInt32((next - n2) / 1000)) }
    }
    let sp = CMIODeviceStopStream(dev.id, sinkID)
    print("stopped (\(st(sp))); enqueued=\(enqueued) dropped=\(dropped)")
}

// MARK: - args

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ n: String) -> String? { if let i = args.firstIndex(of: n), i + 1 < args.count { return args[i + 1] }; return nil }

if args.contains("--list") { listDevices(); exit(0) }
if args.contains("--pattern") {
    let secs = Double(opt("--seconds") ?? "") ?? 30
    let fps = Int(opt("--fps") ?? "") ?? 30
    var w = 1920, h = 1080
    if let s = opt("--size") {
        let p = s.split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, p[0] > 0, p[1] > 0 else { fail("bad --size, use WxH") }
        w = p[0]; h = p[1]
    }
    guard fps > 0, fps <= 120 else { fail("bad --fps") }
    runPattern(seconds: secs, width: w, height: h, fps: fps)
    exit(0)
}
print("usage: obs-cam-probe --list | --pattern [--seconds N] [--size WxH] [--fps N]")
exit(64)
