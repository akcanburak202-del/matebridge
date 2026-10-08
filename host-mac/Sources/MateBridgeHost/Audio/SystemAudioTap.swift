import AppKit
import AudioToolbox
import CoreAudio
import Foundation
import MateBridgeCore

/// System audio capture through a Core Audio process tap (decision 0011). The one place that owns the tap, the private
/// aggregate device and the IOProc.
///
/// - Tap: stereo, global, this process excluded, `.mutedWhenTapped` (the Mac's own output is silent while the tap is
///   read and comes back when it stops or this process dies), private, named `MateBridge-audio`.
/// - Aggregate: private, main sub-device = the default output device (its clock), the tap with drift compensation,
///   tap auto-start; buffer 240 frames (5 ms).
/// - IOProc block on the HAL's real-time I/O thread (no dispatch queue); it only converts and packetizes
///   (`AudioPacketizer`: no allocation, no lock).
/// - Requests coalesce into one desired state (the latest `start`, or nothing after its `stop`); a single reconcile
///   pass on one serial queue builds or tears down to match it. `AudioDeviceCreateIOProcIDWithBlock` shows the audio
///   capture permission prompt and blocks while it is open, so it never runs on the main thread or on a video/input
///   path, and any number of start/stop calls meanwhile leave at most one pending pass. Right before
///   `AudioDeviceStart` the desired state is checked again (a capture no longer wanted is torn down without ever
///   starting: the Mac is not muted for a stale request), and so is the setup: default output (id and UID), output
///   alive, tap format, aggregate rate and buffer layout. If any of them changed while the prompt was open, the
///   half-built capture is torn down and built again (bounded, then `failed`).
/// - The interruption listeners are installed before the blocking call, so a change during the prompt is not missed:
///   its notification runs after the build and interrupts the capture if it did start.
/// - Teardown order: `AudioDeviceStop` -> `AudioDeviceDestroyIOProcID` -> `AudioHardwareDestroyAggregateDevice` ->
///   `AudioHardwareDestroyProcessTap`.
/// - A change of the default output device, the output device or aggregate dying, a sample rate / tap format change,
///   or a wake from sleep is reported as `interrupted`; the streamer then stops this capture and starts a new stream
///   (tap and aggregate are rebuilt).
/// - A capture asked for right after the previous one was torn down (session takeover) can fail to create its tap
///   (`noErr` without a tap object) or aggregate, although the teardown above finished first on this queue: Core Audio
///   apparently still removes the old objects. Such failures are reported as `tap_create` / `aggregate_create`, which
///   `AudioStreamPolicy` retries with a short, growing delay (T-119).
/// - No launch sweep of leaked taps: our tap is private, so it is visible only to this process and goes away with it.
///   Sweeping other processes' taps by name would read `kAudioTapPropertyDescription`, whose ownership is undocumented
///   (a wrong release could crash at launch), for no benefit.
public final class SystemAudioTap: AudioCaptureBackend, @unchecked Sendable {
    public static let tapName = "MateBridge-audio"
    static let aggregateName = "MateBridge-audio-agg"
    static let bufferFrames: UInt32 = 240
    /// Builds attempted in a row when the setup keeps changing under the permission prompt.
    static let maxSetupAttempts = 3

    private struct Request {
        let streamID: UInt16
        let packetizer: AudioPacketizer
        let events: @Sendable (AudioCaptureEvent) -> Void
    }

    private let queue = DispatchQueue(label: "dev.matebridge.audio.tap", qos: .userInitiated)
    private let logger = SessionLogger(component: "audio")
    // Guarded by `lock`: what the streamer wants, and whether a reconcile pass is already queued.
    private let lock = NSLock()
    private var desired: Request?
    private var reconcileQueued = false
    // Confined to `queue`.
    private var run: Run?

    /// One built capture: what has to be torn down, and the listeners that report interruptions.
    private final class Run {
        let streamID: UInt16
        let events: @Sendable (AudioCaptureEvent) -> Void
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var outputDevice = AudioObjectID(kAudioObjectUnknown)
        var format = AudioStreamBasicDescription()
        var nominalRate: Double = 0
        var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                         block: AudioObjectPropertyListenerBlock)] = []
        var interrupted = false

        init(streamID: UInt16, events: @escaping @Sendable (AudioCaptureEvent) -> Void) {
            self.streamID = streamID
            self.events = events
        }
    }

    deinit { HostSleepParticipants.shared.unregister(self) }

    public init() {
        // T-299: on a system sleep, close the capture on the tap queue at once, independent of the session queue. The
        // streamer's later `stop` finds nothing running; a stream wanted again after wake is rebuilt by `start`.
        HostSleepParticipants.shared.register(self, name: "audio") { [weak self] done in
            guard let self else { return done() }
            lock.withLock { desired = nil }
            queue.async { [self] in
                if let r = run { teardown(r) }
                run = nil
                done()
            }
        }
        // Wake from sleep: the HAL may have reset the devices under the aggregate; rebuild.
        Task { @MainActor [weak self] in
            _ = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                queue.async { if let r = self.run { self.interrupt(r, reason: "wake") } }
            }
        }
    }

    // MARK: AudioCaptureBackend

    public func start(streamID: UInt16, packetizer: AudioPacketizer,
                      events: @escaping @Sendable (AudioCaptureEvent) -> Void) {
        lock.withLock { desired = Request(streamID: streamID, packetizer: packetizer, events: events) }
        scheduleReconcile()
    }

    public func stop(streamID: UInt16) {
        lock.withLock { if desired?.streamID == streamID { desired = nil } }
        scheduleReconcile()
    }

    /// App shutdown: tears the capture down, waiting at most `timeoutMs` (the queue may be stuck in the permission
    /// prompt; then the capture is never started, and the mute ends with the process anyway).
    public func shutdown(timeoutMs: Int = 500) {
        lock.withLock { desired = nil }
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if let r = run { teardown(r) }
            run = nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + .milliseconds(timeoutMs))
    }

    // MARK: Reconcile (queue)

    /// At most one pass is queued however many requests arrive while the queue is blocked.
    private func scheduleReconcile() {
        let enqueue = lock.withLock {
            if reconcileQueued { return false }
            reconcileQueued = true
            return true
        }
        if enqueue { queue.async { [self] in reconcile() } }
    }

    private func reconcile() {
        let want = lock.withLock {
            reconcileQueued = false
            return desired
        }
        if let r = run, r.streamID != want?.streamID {
            teardown(r)
            run = nil
            logger.log(.info, "audio_capture_stopped", sessionID: 0, generation: 0, fields: "stream_id=\(r.streamID)")
        }
        if let want, run == nil { build(want, attempt: 1) }
    }

    private func isWanted(_ streamID: UInt16) -> Bool {
        lock.withLock { desired?.streamID == streamID }
    }

    // MARK: Build and teardown (queue)

    private func build(_ request: Request, attempt: Int) {
        let streamID = request.streamID
        let r = Run(streamID: streamID, events: request.events)
        run = r
        func fail(_ reason: String, _ status: OSStatus) {
            teardown(r)
            if run === r { run = nil }
            // Never rebuilt by a later pass of this backend. A transient failure (`AudioCaptureFailure.isTransient`) is
            // retried by the streamer's policy as a new stream, after a delay, on this same queue after this teardown.
            lock.withLock { if desired?.streamID == streamID { desired = nil } }
            request.events(.failed(streamID: streamID, reason: reason, status: status))
        }

        guard let output = Self.defaultOutputDevice() else { return fail(AudioCaptureFailure.noOutputDevice, 0) }
        guard let outputUID = Self.deviceUID(output) else { return fail(AudioCaptureFailure.noOutputUID, 0) }
        r.outputDevice = output

        let exclude = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.name = Self.tapName
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { return fail(AudioCaptureFailure.tapCreate, status) }
        r.tapID = tapID

        guard let format = Self.tapFormat(tapID) else { return fail(AudioCaptureFailure.tapFormat, 0) }
        guard Self.isSupported(format) else {
            let reason = AudioCaptureFailure.unsupportedFormat(sampleRate: Int(format.mSampleRate),
                                                               channels: format.mChannelsPerFrame)
            return fail(reason, 0)
        }
        r.format = format

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            return fail(AudioCaptureFailure.aggregateCreate, status)
        }
        r.aggregateID = aggregateID

        var frames = Self.bufferFrames
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        if status != noErr {  // not fatal: the device's own buffer size works, just with more latency
            logger.log(.warning, "audio_buffer_size_refused", sessionID: 0, generation: 0, fields: "status=\(status)")
        }
        r.nominalRate = Self.nominalRate(aggregateID) ?? 0

        guard let layout = TapBufferLayout.choose(channelsPerBuffer: Self.inputChannelsPerBuffer(aggregateID)) else {
            return fail(AudioCaptureFailure.tapLayout, 0)
        }
        installListeners(r)  // before the blocking call: changes during the prompt reach us afterwards

        // The permission prompt appears here and blocks this queue until answered. nil queue: the block runs on the
        // HAL's real-time I/O thread.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil,
                                                    Self.makeIOBlock(packetizer: request.packetizer, layout: layout))
        guard status == noErr, let procID else { return fail(AudioCaptureFailure.ioprocCreate, status) }
        r.procID = procID

        // The prompt may have been open for a long time: start (and mute the Mac) only if still wanted.
        guard isWanted(streamID) else {
            teardown(r)
            run = nil
            logger.log(.info, "audio_capture_cancelled", sessionID: 0, generation: 0, fields: "stream_id=\(streamID)")
            return
        }
        if let change = Self.changeSinceSetup(r, outputUID: outputUID, layout: layout) {
            teardown(r)
            run = nil
            logger.log(.info, "audio_setup_changed", sessionID: 0, generation: 0,
                       fields: "stream_id=\(streamID) reason=\(change) attempt=\(attempt)")
            guard attempt < Self.maxSetupAttempts else { return fail(AudioCaptureFailure.setupChanged(change), 0) }
            return build(request, attempt: attempt + 1)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { return fail(AudioCaptureFailure.deviceStart, status) }

        logger.log(.info, "audio_capture_started", sessionID: 0, generation: 0,
                   fields: "stream_id=\(streamID) layout=\(layout) buffer_frames=\(Self.bufferFrameSize(aggregateID)) "
                       + "rate=\(Int(r.nominalRate))")
        request.events(.started(streamID: streamID))
    }

    /// Releases everything `r` holds, in the order the HAL requires. Idempotent.
    private func teardown(_ r: Run) {
        removeListeners(r)
        if let procID = r.procID {
            AudioDeviceStop(r.aggregateID, procID)
            AudioDeviceDestroyIOProcID(r.aggregateID, procID)
            r.procID = nil
        }
        if r.aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(r.aggregateID)
            r.aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if r.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(r.tapID)
            r.tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func interrupt(_ r: Run, reason: String) {
        guard run === r, !r.interrupted else { return }
        r.interrupted = true
        logger.log(.info, "audio_capture_interrupted", sessionID: 0, generation: 0,
                   fields: "stream_id=\(r.streamID) reason=\(reason)")
        r.events(.interrupted(streamID: r.streamID, reason: reason))
    }

    /// What changed since `build` read it (nil: nothing). Checked right before `AudioDeviceStart`.
    private static func changeSinceSetup(_ r: Run, outputUID: String, layout: TapBufferLayout) -> String? {
        guard let output = defaultOutputDevice(), output == r.outputDevice, deviceUID(output) == outputUID else {
            return "default_output_changed"
        }
        guard isAlive(output) else { return "device_dead" }
        guard let format = tapFormat(r.tapID), isSupported(format), sameFormat(format, r.format) else {
            return "format_changed"
        }
        guard nominalRate(r.aggregateID) == r.nominalRate else { return "format_changed" }
        guard TapBufferLayout.choose(channelsPerBuffer: inputChannelsPerBuffer(r.aggregateID)) == layout else {
            return "layout_changed"
        }
        return nil
    }

    private static func sameFormat(_ a: AudioStreamBasicDescription, _ b: AudioStreamBasicDescription) -> Bool {
        a.mSampleRate == b.mSampleRate && a.mChannelsPerFrame == b.mChannelsPerFrame && a.mFormatFlags == b.mFormatFlags
            && a.mBitsPerChannel == b.mBitsPerChannel
    }

    // MARK: Listeners (queue)

    /// Each handler compares against the state at build time, so a notification that changes nothing does not
    /// trigger a rebuild (and cannot loop).
    private func installListeners(_ r: Run) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        addListener(r, system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self, weak r] in
            guard let self, let r, Self.defaultOutputDevice() != r.outputDevice else { return }
            interrupt(r, reason: "default_output_changed")
        }
        addListener(r, r.outputDevice, kAudioDevicePropertyDeviceIsAlive) { [weak self, weak r] in
            guard let self, let r, !Self.isAlive(r.outputDevice) else { return }
            interrupt(r, reason: "device_dead")
        }
        addListener(r, r.aggregateID, kAudioDevicePropertyDeviceIsAlive) { [weak self, weak r] in
            guard let self, let r, !Self.isAlive(r.aggregateID) else { return }
            interrupt(r, reason: "aggregate_dead")
        }
        addListener(r, r.aggregateID, kAudioDevicePropertyNominalSampleRate) { [weak self, weak r] in
            guard let self, let r, Self.nominalRate(r.aggregateID) != r.nominalRate else { return }
            interrupt(r, reason: "format_changed")
        }
        addListener(r, r.tapID, kAudioTapPropertyFormat) { [weak self, weak r] in
            guard let self, let r else { return }
            if let now = Self.tapFormat(r.tapID), Self.sameFormat(now, r.format) { return }
            interrupt(r, reason: "format_changed")
        }
    }

    private func addListener(_ r: Run, _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ handler: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            r.listeners.append((object, address, block))
        } else {
            logger.log(.warning, "audio_listener_refused", sessionID: 0, generation: 0, fields: "selector=\(selector)")
        }
    }

    private func removeListeners(_ r: Run) {
        for l in r.listeners {
            var address = l.address
            AudioObjectRemovePropertyListenerBlock(l.object, &address, queue, l.block)
        }
        r.listeners.removeAll()
    }

    // MARK: IOProc (real-time thread)

    /// Converts and packetizes; no allocation, no lock, no logging.
    private static func makeIOBlock(packetizer: AudioPacketizer, layout: TapBufferLayout) -> AudioDeviceIOBlock {
        return { _, inputData, inputTime, _, _ in
            let begin = mach_absolute_time()
            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid) ? time.mHostTime : begin
            let sampleTime: Double? = time.mFlags.contains(.sampleTimeValid) ? time.mSampleTime : nil
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            if buffers.count >= layout.minimumBufferCount {
                switch layout {
                case .interleaved(let i):
                    let b = buffers[i]
                    if b.mNumberChannels == 2, let data = b.mData {
                        packetizer.ingest(.interleaved(UnsafePointer(data.assumingMemoryBound(to: Float.self))),
                                          frames: Int(b.mDataByteSize) / 8, hostTime: hostTime, sampleTime: sampleTime)
                    }
                case .planar(let li, let ri):
                    let l = buffers[li]
                    let r = buffers[ri]
                    if let ld = l.mData, let rd = r.mData {
                        let frames = Int(min(l.mDataByteSize, r.mDataByteSize)) / 4
                        packetizer.ingest(.planar(left: UnsafePointer(ld.assumingMemoryBound(to: Float.self)),
                                                  right: UnsafePointer(rd.assumingMemoryBound(to: Float.self))),
                                          frames: frames, hostTime: hostTime, sampleTime: sampleTime)
                    }
                }
            }
            packetizer.recordCallback(ticks: mach_absolute_time() &- begin)
        }
    }

    // MARK: Core Audio property helpers

    private static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        let isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        return format.mSampleRate == Double(AudioStreamPolicy.sampleRate)
            && format.mChannelsPerFrame == UInt32(AudioStreamPolicy.channels) && isFloat32
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func u32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        guard let id = u32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    private static func isAlive(_ device: AudioObjectID) -> Bool {
        (u32(device, kAudioDevicePropertyDeviceIsAlive) ?? 0) != 0
    }

    private static func bufferFrameSize(_ device: AudioObjectID) -> UInt32 {
        u32(device, kAudioDevicePropertyBufferFrameSize) ?? 0
    }

    private static func nominalRate(_ device: AudioObjectID) -> Double? {
        var address = address(kAudioDevicePropertyNominalSampleRate)
        var value: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?  // documented: the caller releases the UID string
    }

    /// This process's audio object, excluded from the tap (nil when the HAL has none for it yet).
    private static func ownProcessObject() -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = address(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        return AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr ? format : nil
    }

    /// `mNumberChannels` of each input buffer of `device` (its input stream configuration).
    private static func inputChannelsPerBuffer(_ device: AudioObjectID) -> [Int] {
        var address = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return [] }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }
}
