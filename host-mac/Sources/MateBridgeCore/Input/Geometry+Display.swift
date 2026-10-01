// Display-space half of host input injection (T-023): everything between the state machine's `InjectAction`s and
// the CGEvent poster that can be decided without a Mac, so it is unit-tested.
//
//   InjectAction --InjectionPlanner--> MacEvent --(Host: CGEventPoster)--> CGEvent.post
//
// This file: `DisplayGeometry`, the one coordinate conversion (PROTOCOL.md section 1). Beside it in Core/Input:
// MacEvent.swift (the seam vocabulary and `InjectionEnvironment`), ClickCounter.swift, InjectionPlanner.swift (the
// injector's own state), InputPipeline.swift (session lifecycle and release-all), OwedRelease.swift (releases the Mac
// may not have received), MacEvent+Closing.swift and ReleaseRecord.swift (release log names).
// Nothing here posts events, checks permissions or looks at the screen; the Host passes an `InjectionEnvironment`.
//
// Rule identifiers used as test-name prefixes: GEO-* geometry, CLICK-* click state, PLAN-* planner, PIPE-* pipeline,
// MAC-* closing events, OWED-* owed releases.

// MARK: - Display geometry

/// A position in the global display coordinate space (points, origin top-left of the main display, y down).
public struct DisplayPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = DisplayPoint(x: 0, y: 0)
}

/// The virtual display in global coordinates: `CGDisplayBounds` plus its backing scale. This is the single place that
/// turns normalized `u16` positions into points (PROTOCOL.md section 1): `x_pt = origin + v / 65535 * extent`,
/// clamped to `[origin, origin + extent - 1/scale]`. The origin is never assumed to be (0, 0).
public struct DisplayGeometry: Equatable, Sendable {
    public let originX: Double
    public let originY: Double
    public let widthPt: Double
    public let heightPt: Double
    /// Pixels per point (2 for the HiDPI virtual display).
    public let scale: Double

    /// nil for a display that cannot be mapped onto: non-finite values, empty size or a non-positive scale.
    public init?(originX: Double, originY: Double, widthPt: Double, heightPt: Double, scale: Double) {
        guard originX.isFinite, originY.isFinite, widthPt.isFinite, heightPt.isFinite, scale.isFinite,
              widthPt > 0, heightPt > 0, scale > 0 else { return nil }
        self.originX = originX
        self.originY = originY
        self.widthPt = widthPt
        self.heightPt = heightPt
        self.scale = scale
    }

    /// GEO-*: normalized position to global points.
    public func point(x: UInt16, y: UInt16) -> DisplayPoint {
        DisplayPoint(x: NormalizedCoord.toPoints(x, origin: originX, extent: widthPt, scale: scale),
                     y: NormalizedCoord.toPoints(y, origin: originY, extent: heightPt, scale: scale))
    }

    public func point(_ p: PenPoint) -> DisplayPoint { point(x: p.x, y: p.y) }

    public var center: DisplayPoint { DisplayPoint(x: originX + widthPt / 2, y: originY + heightPt / 2) }

    /// Whether `p` is a point of this display, i.e. inside the bounds `point(x:y:)` and `clamped` map to.
    public func contains(_ p: DisplayPoint) -> Bool {
        let eps = 1e-9
        return p.x >= originX - eps && p.x <= originX + widthPt - 1 / scale + eps
            && p.y >= originY - eps && p.y <= originY + heightPt - 1 / scale + eps
    }

    /// A live cursor position, if it is on this display: inside the half-open bounds `[origin, origin + extent)` (the
    /// cursor can rest on the last fractional point, which `contains` excludes; a point at `origin + extent` belongs to
    /// the neighbor), then clamped to the bounds `point(x:y:)` uses. nil for a point on another display or non-finite.
    public func onDisplay(_ p: DisplayPoint) -> DisplayPoint? {
        guard p.x.isFinite, p.y.isFinite, p.x >= originX, p.x < originX + widthPt, p.y >= originY,
              p.y < originY + heightPt else { return nil }
        return clamped(p)
    }

    /// The same bounds `point(x:y:)` uses. A non-finite value maps to the origin.
    public func clamped(_ p: DisplayPoint) -> DisplayPoint {
        DisplayPoint(x: Self.clamp(p.x, origin: originX, extent: widthPt, scale: scale),
                     y: Self.clamp(p.y, origin: originY, extent: heightPt, scale: scale))
    }

    /// Relative cursor movement (`POINTER_REL`): the cursor stays on the display.
    public func moved(_ p: DisplayPoint, dx: Double, dy: Double) -> DisplayPoint {
        clamped(DisplayPoint(x: p.x + dx, y: p.y + dy))
    }

    private static func clamp(_ v: Double, origin: Double, extent: Double, scale: Double) -> Double {
        guard v.isFinite else { return origin }
        let upper = Swift.max(origin + extent - 1 / scale, origin)
        return Swift.min(Swift.max(v, origin), upper)
    }
}

