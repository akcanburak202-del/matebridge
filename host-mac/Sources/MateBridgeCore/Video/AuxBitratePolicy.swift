import Foundation

/// The auxiliary view's bitrate target in packed full colour (decision 0034, T-262). Pure.
///
/// T-262 measured (probes/yuv444-probe `quality`, pick main chroma, 2800x1840, 30 Mbps main): the auxiliary session
/// only follows its `AverageBitRate` where the content needs more than the target (heavy or noisy motion); on text,
/// scrolling and static frames VideoToolbox stays under it whatever the target is. Where it binds, half the main
/// target (the T-258 value) gave an auxiliary stream up to 1.4x the main one on grainy video; a quarter keeps the
/// auxiliary / main ratio at about 0.25-0.35 there for roughly 1 dB less RGB PSNR, still far above plain 4:2:0.
public enum AuxBitratePolicy {
    /// Auxiliary target as a percentage of the main target.
    public static let percentOfMain = 25
    /// Lowest target; the auxiliary view still carries the colour edges of text at small main targets.
    public static let floorKbps = 1_000

    /// The auxiliary `AverageBitRate` (kbps) for a main target in kbps.
    public static func kbps(main: Int) -> Int {
        max(floorKbps, main * percentOfMain / 100)
    }
}
