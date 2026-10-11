import AudioToolbox
import Foundation

/// Real AAC-LC encoder (system `AudioConverter`, decision 0038): 48 kHz stereo s16le in, 96 kbps raw access units out.
/// Not thread-safe; used from the streamer queue only.
public final class AudioToolboxAACConverter: AACConverting, @unchecked Sendable {
    public enum Failure: Error, Equatable {
        case create(OSStatus)
        case encode(OSStatus)
    }

    public static let bitRate: UInt32 = 96_000
    private static let noMoreData: OSStatus = 0x6E6F_6D6F  // "nomo": private end-of-input marker
    private static let fallbackPriming = 2112

    private var converter: AudioConverterRef?
    public private(set) var primingFrames: Int = AudioToolboxAACConverter.fallbackPriming
    private var maxPacketBytes = 1536

    public init() throws {
        var input = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
            mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var output = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 2,  // kMPEG4Object_AAC_LC
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0,
            mReserved: 0)
        var ref: AudioConverterRef?
        let status = AudioConverterNew(&input, &output, &ref)
        guard status == noErr, let ref else { throw Failure.create(status) }
        converter = ref
        var rate = Self.bitRate
        let rateStatus = AudioConverterSetProperty(ref, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size),
                                                   &rate)
        guard rateStatus == noErr else {
            AudioConverterDispose(ref)
            converter = nil
            throw Failure.create(rateStatus)
        }
        // Constant bit rate: a predictable 96 kbps on the wire (decision 0038). Best effort: the default mode still works.
        var mode = UInt32(kAudioCodecBitRateControlMode_Constant)
        _ = AudioConverterSetProperty(ref, kAudioCodecPropertyBitRateControlMode, UInt32(MemoryLayout<UInt32>.size),
                                      &mode)
        var prime = AudioConverterPrimeInfo()
        var size = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
        if AudioConverterGetProperty(ref, kAudioConverterPrimeInfo, &size, &prime) == noErr, prime.leadingFrames > 0 {
            primingFrames = Int(prime.leadingFrames)
        }
        var maxSize: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioConverterGetProperty(ref, kAudioConverterPropertyMaximumOutputPacketSize, &size, &maxSize) == noErr,
           maxSize > 0 {
            maxPacketBytes = Int(maxSize)
        }
    }

    deinit {
        if let converter { AudioConverterDispose(converter) }
    }

    public func reset() {
        if let converter { AudioConverterReset(converter) }
    }

    private final class InputContext {
        let base: UnsafeRawPointer
        let frames: UInt32
        var consumed = false
        init(base: UnsafeRawPointer, frames: UInt32) {
            self.base = base
            self.frames = frames
        }
    }

    public func encode(_ pcm: [UInt8]) throws -> [UInt8]? {
        guard let converter, pcm.count == AACStage.unitFrames * 4 else { throw Failure.encode(kAudio_ParamError) }
        var out = [UInt8](repeating: 0, count: maxPacketBytes)
        var produced: UInt32 = 0
        var written = 0
        var status: OSStatus = noErr
        pcm.withUnsafeBytes { raw in
            let context = InputContext(base: raw.baseAddress!, frames: UInt32(AACStage.unitFrames))
            out.withUnsafeMutableBytes { outRaw in
                var bufferList = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outRaw.count),
                                          mData: outRaw.baseAddress))
                var packets: UInt32 = 1
                var description = AudioStreamPacketDescription()
                status = withExtendedLifetime(context) {
                    AudioConverterFillComplexBuffer(
                        converter,
                        { _, ioPackets, ioData, _, userData in
                            let ctx = Unmanaged<InputContext>.fromOpaque(userData!).takeUnretainedValue()
                            if ctx.consumed {
                                ioPackets.pointee = 0
                                return AudioToolboxAACConverter.noMoreData
                            }
                            ctx.consumed = true
                            ioPackets.pointee = ctx.frames
                            ioData.pointee.mNumberBuffers = 1
                            ioData.pointee.mBuffers.mNumberChannels = 2
                            ioData.pointee.mBuffers.mDataByteSize = ctx.frames * 4
                            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: ctx.base)
                            return noErr
                        },
                        Unmanaged.passUnretained(context).toOpaque(), &packets, &bufferList, &description)
                }
                produced = packets
                written = Int(bufferList.mBuffers.mDataByteSize)
            }
        }
        guard status == noErr || status == Self.noMoreData else { throw Failure.encode(status) }
        guard produced > 0, written > 0 else { return nil }
        return Array(out.prefix(written))
    }
}
