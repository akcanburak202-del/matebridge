/// Which buffers of the aggregate device's input buffer list carry the tap's stereo audio.
///
/// The private aggregate has the default output device as its main sub-device plus the process tap. If that device
/// also has inputs (an audio interface with a microphone), their streams come first and the tap stream is appended
/// last. So the tap is the last buffer if it is stereo interleaved, or the last two mono buffers.
public enum TapBufferLayout: Equatable, Sendable {
    case interleaved(buffer: Int)
    case planar(left: Int, right: Int)

    /// `channelsPerBuffer`: `mNumberChannels` of each input buffer, in order. nil: no usable stereo tap stream.
    public static func choose(channelsPerBuffer: [Int]) -> TapBufferLayout? {
        guard let last = channelsPerBuffer.indices.last else { return nil }
        if channelsPerBuffer[last] == 2 { return .interleaved(buffer: last) }
        if channelsPerBuffer[last] == 1, last >= 1, channelsPerBuffer[last - 1] == 1 {
            return .planar(left: last - 1, right: last)
        }
        return nil
    }

    /// The buffer count the IOProc must see for this layout to apply (at least).
    public var minimumBufferCount: Int {
        switch self {
        case .interleaved(let b): return b + 1
        case .planar(_, let r): return r + 1
        }
    }
}
