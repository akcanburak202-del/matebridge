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
/// - IOProc on its own high-priority queue; it only converts and packetizes (`AudioPacketizer`: no allocation, no lock).
/// - Everything else runs on one serial queue. `AudioDeviceCreateIOProcIDWithBlock` shows the audio capture permission
///   prompt and blocks while it is open, so it never runs on the main thread or on a video/input path; requests queued
///   meanwhile (a stop) run right after it.
/// - Teardown order: `AudioDeviceStop` -> `AudioDeviceDestroyIOProcID` -> `AudioHardwareDestroyAggregateDevice` ->
///   `AudioHardwareDestroyProcessTap`.
/// - A change of the default output device, the output device dying, or a wake from sleep is reported as
///   `interrupted`; the streamer then stops this capture and starts a new stream (tap and aggregate are rebuilt).
public final class SystemAudioTap: AudioCaptureBackend, @unchecked Sendable {
    public static let tapName = "MateBridge-audio"
    static let aggregateName = "MateBridge-audio-agg"
    static let bufferFrames: UInt32 = 240

    private let queue = DispatchQueue(label: "dev.matebridge.audio.tap", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "dev.matebridge.audio.io", qos: .userInteractive)
    private let logger = SessionLogger(component: "audio")
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
        var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress,
                         block: AudioObjectPropertyListenerBlock)] = []
        var interrupted = false

        init(streamID: UInt16, events: @escaping @Sendable (AudioCaptureEvent) -> Void) {
            self.streamID = streamID
            self.events = events
        }
    }

    public init() {
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
        queue.async { [self] in build(streamID: streamID, packetizer: packetizer, events: events) }
    }

    public func stop(streamID: UInt16) {
        queue.async { [self] in
            guard let r = run, r.streamID == streamID else { return }
            teardown(r)
            run = nil
            logger.log(.info, "audio_capture_stopped", sessionID: 0, generation: 0, fields: "stream_id=\(streamID)")
        }
    }

    /// App shutdown: tears the capture down, waiting at most `timeoutMs` (the queue may be stuck in the permission
    /// prompt; the mute ends with the process anyway).
    public func shutdown(timeoutMs: Int = 500) {
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            if let r = run { teardown(r) }
            run = nil
            done.signal()
        }
        _ = done.wait(timeout: .now() + .milliseconds(timeoutMs))
    }

    /// Launch: destroys taps named `MateBridge-audio` that an earlier run left behind (a public tap outlives a killed
    /// process). Lists taps only; creates nothing and needs no permission.
    public func cleanUpLeakedTaps() {
        queue.async { [self] in
            guard run == nil else { return }
            var destroyed = 0
            for id in Self.tapList() where Self.tapName(id) == Self.tapName {
                if AudioHardwareDestroyProcessTap(id) == noErr { destroyed += 1 }
            }
            if destroyed > 0 {
                logger.log(.warning, "audio_leaked_taps_removed", sessionID: 0, generation: 0, fields: "count=\(destroyed)")
            }
        }
    }

    // MARK: Build and teardown (queue)

    private func build(streamID: UInt16, packetizer: AudioPacketizer,
                       events: @escaping @Sendable (AudioCaptureEvent) -> Void) {
        if let old = run { teardown(old) }
        let r = Run(streamID: streamID, events: events)
        run = r
        func fail(_ reason: String, _ status: OSStatus) {
            teardown(r)
            if run === r { run = nil }
            events(.failed(streamID: streamID, reason: reason, status: status))
        }

        guard let output = Self.defaultOutputDevice() else { return fail("no_output_device", 0) }
        guard let outputUID = Self.deviceUID(output) else { return fail("no_output_uid", 0) }
        r.outputDevice = output

        let exclude = Self.ownProcessObject().map { [$0] } ?? []
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        description.name = Self.tapName
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else { return fail("tap_create", status) }
        r.tapID = tapID

        guard let format = Self.tapFormat(tapID) else { return fail("tap_format", 0) }
        let isFloat32 = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        guard format.mSampleRate == Double(AudioStreamPolicy.sampleRate),
              format.mChannelsPerFrame == UInt32(AudioStreamPolicy.channels), isFloat32 else {
            return fail("tap_format_\(Int(format.mSampleRate))hz_\(format.mChannelsPerFrame)ch", 0)
        }

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
        guard status == noErr, aggregateID != kAudioObjectUnknown else { return fail("aggregate_create", status) }
        r.aggregateID = aggregateID

        var frames = Self.bufferFrames
        var address = Self.address(kAudioDevicePropertyBufferFrameSize)
        status = AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)
        if status != noErr {  // not fatal: the device's own buffer size works, just with more latency
            logger.log(.warning, "audio_buffer_size_refused", sessionID: 0, generation: 0, fields: "status=\(status)")
        }

        guard let layout = TapBufferLayout.choose(channelsPerBuffer: Self.inputChannelsPerBuffer(aggregateID)) else {
            return fail("tap_layout", 0)
        }

        // The permission prompt appears here and blocks this queue until answered.
        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue,
                                                    Self.makeIOBlock(packetizer: packetizer, layout: layout))
        guard status == noErr, let procID else { return fail("ioproc_create", status) }
        r.procID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { return fail("device_start", status) }

        installListeners(r)
        logger.log(.info, "audio_capture_started", sessionID: 0, generation: 0,
                   fields: "stream_id=\(streamID) layout=\(layout) buffer_frames=\(Self.bufferFrameSize(aggregateID))")
        events(.started(streamID: streamID))
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

    // MARK: Listeners (queue)

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
    }

    private func addListener(_ r: Run, _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             _ handler: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            r.listeners.append((object, address, block))
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

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var address = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
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

    private static func tapList() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyTapList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func tapName(_ tap: AudioObjectID) -> String? {
        var address = address(kAudioTapPropertyDescription)
        var value: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue().name
    }
}
