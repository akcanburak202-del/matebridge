import Foundation

public enum PenPattern: String, CaseIterable, Sendable {
    case ramp, circle, tilt

    /// Samples of one stroke (down ... up) inside the given rectangle (global points).
    public func strokeSamples(originX: Double, originY: Double, width: Double, height: Double,
                              count: Int = 120) -> [PenSample] {
        precondition(count >= 3)
        var out: [PenSample] = []
        for i in 0..<count {
            let t = Double(i) / Double(count - 1)
            let phase: PenSample.Phase = i == 0 ? .down : (i == count - 1 ? .up : .move)
            let s: PenSample
            switch self {
            case .ramp:
                // Horizontal line, pressure 0 -> 1 -> 0.
                let p = 1 - abs(2 * t - 1)
                s = PenSample(x: originX + width * t, y: originY + height / 2, pressure: p, tiltX: 0, tiltY: 0, phase: phase)
            case .circle:
                let a = 2 * Double.pi * t
                let r = min(width, height) / 2
                s = PenSample(x: originX + width / 2 + r * cos(a), y: originY + height / 2 + r * sin(a),
                              pressure: 0.3 + 0.7 * (0.5 - 0.5 * cos(a)), tiltX: 0, tiltY: 0,
                              rotation: a * 180 / .pi, phase: phase)
            case .tilt:
                // Constant pressure; tilt X sweeps -1 -> 1 while tilt Y sweeps 1 -> -1.
                s = PenSample(x: originX + width * t, y: originY + height / 2, pressure: 0.6,
                              tiltX: -1 + 2 * t, tiltY: 1 - 2 * t, phase: phase)
            }
            out.append(s)
        }
        out[out.count - 1].pressure = 0   // clean release
        return out
    }
}
