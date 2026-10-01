import Foundation
import MateBridgeCore

/// Wiring of host audio streaming (T-094) for the thin app target: the Core Audio tap behind `AudioStreamer`,
/// on the host clock and the host log (`component=audio`).
public enum HostAudio {
    public static func makeStreamer(tap: SystemAudioTap,
                                    environment: [String: String] = ProcessInfo.processInfo.environment)
        -> AudioStreamer {
        let logger = SessionLogger(component: "audio")
        return AudioStreamer(
            backend: tap, disabled: AudioKnob.isDisabled(environment),
            clock: .init(nowUs: { HostClock.nowUs() }, hostTicksToUs: { HostClock.us(fromHostTicks: $0) }),
            log: { level, event, sessionID, fields in
                logger.log(level, event, sessionID: sessionID, generation: 0, fields: fields)
            })
    }
}
