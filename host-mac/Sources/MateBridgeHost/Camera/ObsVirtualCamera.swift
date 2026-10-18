import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import MateBridgeCore

/// The OBS Studio virtual camera as the Mac end of the tablet camera (decision 0040, T-351/T-354): finds its CoreMediaIO
/// device, watches whether an app uses it, and writes frames into its sink stream. Written independently from the
/// public CoreMediaIO API (no OBS code). Never requests camera access: it only talks to the sink stream, which needs
/// no camera permission (verified by T-351), and it never opens the source stream.
///
/// While nothing is being watched there is no CMIO listener and no timer. All CMIO work runs on one serial queue.
final class ObsVirtualCamera: @unchecked Sendable {
    /// The OBS extension's fixed stream format (OBS 32.2.2): 1920x1080 BGRA 30 fps.
    static let sinkWidth = 1920
    static let sinkHeight = 1080
    static let sinkFps = 30

    /// What the watcher reports; always called on the camera queue given to `startMonitoring`.
    struct Environment: Equatable, Sendable {
        var deviceAvailable: Bool
        /// `kCMIODevicePropertyDeviceIsRunningSomewhere` of the device (false without a device).
        var running: Bool
    }

    private let queue = DispatchQueue(label: "dev.matebridge.camera.cmio", qos: .userInitiated)
    private let logger = SessionLogger(component: "camera")

    // Everything below is confined to `queue`.
    private var deviceID: CMIOObjectID?
    private var sinkID: CMIOStreamID?
    private var monitoring = false
    private var hardwareListener: CMIOObjectPropertyListenerBlock?
    private var deviceListener: CMIOObjectPropertyListenerBlock?
    private var listenedDevice: CMIOObjectID?
    private var lastReported: Environment?
    private var onChange: (@Sendable (Environment) -> Void)?
    private var onChangeQueue: DispatchQueue?

    // Sink writing.
    private var sinkQueue: CMSimpleQueue?
    private var sinkStarted = false
    private var sinkPaused = false
    /// False until `enableWrites()`, false again after `stopSink()`: an in-flight frame that finishes after STOP must not
    /// restart the sink (T-357 r2). A probe pause keeps it true.
    private var writesEnabled = false
    private var formatDescription: CMFormatDescription?
    private var enqueued = 0
    private var queueFull = 0
    private var pausedDrops = 0
    /// IDs of the stream `CMIODeviceStartStream` was called for; `refresh()` may replace `deviceID`/`sinkID` later.
    private var startedStream: (device: CMIOObjectID, sink: CMIOStreamID)?

    // Staging between the camera coordinator and the CMIO queue: one frame, newest wins (own lock, any thread).
    private let stagingLock = NSLock()
    private var staged: (CameraPixelBuffer, @Sendable () -> Void)?
    private var drainScheduled = false
    private var stagingDrops = 0

    // MARK: - Watching

    /// Starts watching the device list and the device's `IsRunningSomewhere`. `handler` runs on `handlerQueue`, first
    /// with the state right now, then on every change. Replaces an earlier watch.
    func startMonitoring(handlerQueue: DispatchQueue, _ handler: @escaping @Sendable (Environment) -> Void) {
        queue.async { [self] in
            stopMonitoringLocked()
            monitoring = true
            onChange = handler
            onChangeQueue = handlerQueue
            var address = Self.address(kCMIOHardwarePropertyDevices)
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let strong = self else { return }
                strong.queue.async { strong.refresh() }
            }
            hardwareListener = block
            let status = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block)
            if status != 0 {
                logger.log(.warning, "camera_cmio", sessionID: 0, generation: 0, fields: "state=hardware_listener_failed status=\(status)")
            }
            refresh()
        }
    }

    /// Removes every listener. After this returns to the queue nothing of the watch remains.
    func stopMonitoring() {
        queue.async { [self] in stopMonitoringLocked() }
    }

    private func stopMonitoringLocked() {
        guard monitoring else { return }
        monitoring = false
        if let block = hardwareListener {
            var address = Self.address(kCMIOHardwarePropertyDevices)
            CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block)
        }
        hardwareListener = nil
        removeDeviceListener()
        onChange = nil
        onChangeQueue = nil
        lastReported = nil
    }

    private func removeDeviceListener() {
        if let block = deviceListener, let device = listenedDevice {
            var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        deviceListener = nil
        listenedDevice = nil
    }

    /// Re-reads the device and its running state, re-attaches the device listener if the device changed, reports changes.
    private func refresh() {
        guard monitoring else { return }
        let found = Self.findDevice()
        deviceID = found?.device
        sinkID = found?.sink
        if listenedDevice != found?.device {
            removeDeviceListener()
            if let device = found?.device {
                var address = Self.address(kCMIODevicePropertyDeviceIsRunningSomewhere)
                let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                    guard let strong = self else { return }
                    strong.queue.async { strong.refresh() }
                }
                if CMIOObjectAddPropertyListenerBlock(device, &address, queue, block) == 0 {
                    deviceListener = block
                    listenedDevice = device
                }
            }
        }
        var running = false
        if let device = found?.device { running = Self.uint32(device, kCMIODevicePropertyDeviceIsRunningSomewhere) == 1 }
        let env = Environment(deviceAvailable: found != nil, running: running)
        guard env != lastReported else { return }
        lastReported = env
        if let handler = onChange, let handlerQueue = onChangeQueue {
            handlerQueue.async { handler(env) }
        }
    }

    // MARK: - Sink

    /// Frames this process wrote, dropped for a full queue, and dropped while paused (since the last call).
    func takeSinkCounters() -> (written: Int, queueFull: Int, paused: Int) {
        let staged = stagingLock.withLock { () -> Int in
            defer { stagingDrops = 0 }
            return stagingDrops
        }
        return queue.sync {
            defer { enqueued = 0; queueFull = 0; pausedDrops = 0 }
            return (enqueued, queueFull + staged, pausedDrops)
        }
    }

    /// The device's `IsRunningSomewhere` read right now (false without a device). Blocks briefly on the CMIO queue; call it
    /// from a queue the CMIO queue never waits on (the camera coordinator's).
    func readRunning() -> Bool {
        queue.sync {
            guard let device = deviceID ?? Self.findDevice()?.device else { return false }
            return Self.uint32(device, kCMIODevicePropertyDeviceIsRunningSomewhere) == 1
        }
    }

    /// Hands a decoded BGRA frame (already at the sink size) to the OBS extension. The first call starts the sink stream
    /// and runs `onStarted`. A frame is dropped (and counted) when paused or when the sink queue is full: nothing waits.
    ///
    /// Staging is bounded (T-357, Codex P2): at most one frame waits for the CMIO queue, and a newer frame replaces it (the
    /// replaced one counts as `queue_full`), so a CMIO queue slower than the decoder cannot pile up retained buffers.
    func write(_ frame: CameraPixelBuffer, onStarted: @escaping @Sendable () -> Void) {
        let schedule = stagingLock.withLock { () -> Bool in
            if staged != nil { stagingDrops += 1 }
            staged = (frame, onStarted)
            let start = !drainScheduled
            drainScheduled = true
            return start
        }
        guard schedule else { return }
        queue.async { [self] in
            while true {
                let next = stagingLock.withLock { () -> (CameraPixelBuffer, @Sendable () -> Void)? in
                    guard let item = staged else { drainScheduled = false; return nil }
                    staged = nil
                    return item
                }
                guard let (frame, onStarted) = next else { return }
                writeLocked(frame, onStarted: onStarted)
            }
        }
    }

    private func writeLocked(_ frame: CameraPixelBuffer, onStarted: @Sendable () -> Void) {
        do {
            let pixelBuffer = frame.value
            guard writesEnabled else { return }
            guard !sinkPaused else { pausedDrops += 1; return }
            if !sinkStarted {
                guard startSinkLocked() else { return }
                onStarted()
            }
            guard let q = sinkQueue, let fd = formatDescription(for: pixelBuffer) else { return }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(Self.sinkFps)),
                                            presentationTimeStamp: CMTime(value: CMTimeValue(DispatchTime.now().uptimeNanoseconds),
                                                                          timescale: 1_000_000_000),
                                            decodeTimeStamp: .invalid)
            var sampleOut: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescription: fd, sampleTiming: &timing,
                                                           sampleBufferOut: &sampleOut) == 0, let sample = sampleOut else { return }
            let ref = Unmanaged.passRetained(sample)  // the queue owns one retain on success
            if CMSimpleQueueEnqueue(q, element: ref.toOpaque()) == 0 {
                enqueued += 1
            } else {
                queueFull += 1
                ref.release()
            }
        }
    }

    /// A probe pause: stops the sink stream so the device's running state shows other clients only. Frames written while
    /// paused are dropped.
    func pauseSink() {
        queue.async { [self] in
            sinkPaused = true
            stopSinkLocked()
        }
    }

    /// Ends a probe pause; the next frame starts the stream again.
    func resumeSink() {
        queue.async { [self] in sinkPaused = false }
    }

    /// An explicit start: a camera connection is (about to be) active, frames may start the sink stream.
    func enableWrites() {
        queue.async { [self] in writesEnabled = true }
    }

    /// Stops the sink stream for good (STOP, the connection ended). Idempotent.
    func stopSink() {
        queue.async { [self] in
            writesEnabled = false
            sinkPaused = false
            stopSinkLocked()
        }
    }

    private func startSinkLocked() -> Bool {
        guard let device = deviceID ?? Self.findDevice()?.device, let sink = sinkID ?? Self.findDevice()?.sink else {
            logger.log(.warning, "camera_cmio", sessionID: 0, generation: 0, fields: "state=sink_missing")
            return false
        }
        deviceID = device
        sinkID = sink
        var queueOut: Unmanaged<CMSimpleQueue>?
        let copied = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &queueOut)
        guard copied == 0, let q = queueOut?.takeRetainedValue() else {
            logger.log(.warning, "camera_cmio", sessionID: 0, generation: 0, fields: "state=queue_failed status=\(copied)")
            return false
        }
        let started = CMIODeviceStartStream(device, sink)
        guard started == 0 else {
            logger.log(.warning, "camera_cmio", sessionID: 0, generation: 0, fields: "state=start_failed status=\(started)")
            return false
        }
        sinkQueue = q
        startedStream = (device, sink)
        sinkStarted = true
        logger.log(.info, "camera_cmio", sessionID: 0, generation: 0, fields: "state=sink_started")
        return true
    }

    private func stopSinkLocked() {
        // The IDs of the stream that was started, not the current lookup: `refresh()` may have lost the device meanwhile.
        // Local state is cleared whatever the stop returns, so the next start begins clean.
        guard sinkStarted else { return }
        let stream = startedStream
        sinkStarted = false
        sinkQueue = nil
        startedStream = nil
        guard let (device, sink) = stream else { return }
        let status = CMIODeviceStopStream(device, sink)
        logger.log(.info, "camera_cmio", sessionID: 0, generation: 0,
                   fields: "state=sink_stopped status=\(status) written=\(enqueued) queue_full=\(queueFull)")
    }

    private func formatDescription(for pixelBuffer: CVPixelBuffer) -> CMFormatDescription? {
        if let fd = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(fd, imageBuffer: pixelBuffer) { return fd }
        var fdOut: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &fdOut) == 0 else { return nil }
        formatDescription = fdOut
        return fdOut
    }

    // MARK: - Device lookup (static, no state)

    /// The OBS Virtual Camera CMIO device and its sink stream (the `direction == 0` stream: device-relative, data INTO
    /// the device). nil when OBS or its camera extension is not installed and started once.
    static func findDevice() -> (device: CMIOObjectID, sink: CMIOStreamID)? {
        let all = ids(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        let wanted = obsUUID()?.uppercased()
        for d in all {
            let uid = string(d, kCMIODevicePropertyDeviceUID)?.uppercased()
            let name = string(d, kCMIOObjectPropertyName)
            guard (wanted != nil && uid == wanted) || name == "OBS Virtual Camera" else { continue }
            let streams = ids(d, kCMIODevicePropertyStreams)
            if let sink = streams.first(where: { uint32($0, kCMIOStreamPropertyDirection) == 0 }) { return (d, sink) }
        }
        return nil
    }

    /// True when a sink stream of the OBS device exists right now.
    static var isInstalled: Bool { findDevice() != nil }

    private static func obsUUID() -> String? {
        let plist = "/Applications/OBS.app/Contents/PlugIns/mac-virtualcam.plugin/Contents/Info.plist"
        return (NSDictionary(contentsOfFile: plist)?["OBSCameraDeviceUUID"] as? String)
    }

    private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func ids(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &a, 0, nil, &size) == 0, size > 0 else { return [] }
        var out = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, &out) == 0 else { return [] }
        return out
    }

    private static func string(_ object: CMIOObjectID, _ selector: Int) -> String? {
        var a = address(selector)
        var used: UInt32 = 0
        var value: Unmanaged<CFString>?
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { CMIOObjectGetPropertyData(object, &a, 0, nil, size, &used, $0) }
        guard status == 0, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func uint32(_ object: CMIOObjectID, _ selector: Int) -> UInt32? {
        var a = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &a, 0, nil, 4, &used, &value) == 0 else { return nil }
        return value
    }
}
