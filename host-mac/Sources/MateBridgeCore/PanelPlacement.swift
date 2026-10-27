import CoreGraphics

/// Pure placement check for the approval window (T-383): is a window frame still usefully visible on any screen?
public enum PanelPlacement {
    /// True when less than half of `frame`'s area lies on a single screen (no screens at all counts as off-screen).
    public static func isOffscreen(frame: CGRect, screens: [CGRect]) -> Bool {
        let area = frame.width * frame.height
        guard area > 0 else { return true }
        let best = screens.map { screen -> CGFloat in
            let i = frame.intersection(screen)
            return i.isNull ? 0 : i.width * i.height
        }.max() ?? 0
        return best < area * 0.5
    }
}
