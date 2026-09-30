// Pen half of the input state machine: the PROTOCOL.md section 4 PEN table, the latch rule, and the double-tap
// eraser mode of decision 0006.

extension InputStateMachine {
    /// The tool reported to the Mac: the real eraser is always the eraser; in eraser mode the pen is the eraser too.
    func effectiveTool(_ reported: PenTool) -> PenTool {
        (isEraserMode || reported == .eraser) ? .eraser : .pen
    }

    /// ERASER-*: `DOUBLE_TAP` flips eraser mode. The tool change reaches the Mac with the next PEN sample, through
    /// the ordinary tool-change rule (PEN-8). Unknown gestures are ignored.
    mutating func handlePenGesture(_ gesture: PenGesture) {
        if gesture.gesture == .doubleTap { isEraserMode.toggle() }
    }

    mutating func handlePen(_ batch: PenBatch, now: UInt64) -> [InjectAction] {
        lastPenSampleAt = now
        var out: [InjectAction] = []
        for sample in batch.samples {
            processPenSample(effectiveTool(batch.tool), sample, into: &out)
        }
        return out
    }

    /// One sample, following the section 4 table row by row. `tool` is already the effective tool.
    private mutating func processPenSample(_ tool: PenTool, _ sample: PenSample, into out: inout [InjectAction]) {
        // PEN-9: CONTACT without IN_RANGE counts as flags = 0.
        let flags = sample.flags.normalized
        let inRange = flags.contains(.inRange)
        var wantsContact = inRange && flags.contains(.contact)
        let strokeStart = wantsContact && flags.contains(.strokeStart)

        // PEN-8: a different tool closes the old one first (up if needed, then leave). If that interrupted a
        // stroke, the new tool must not continue it as a new stroke, so it starts latched (LATCH-7).
        if let active = activePen, active.tool != tool {
            closePen(into: &out)
            if active.contact { latchedTools.insert(tool) }
        }

        // LATCH-*: while latched, a CONTACT sample without STROKE_START is a stale mid-stroke sample and counts as
        // hover. The latch lifts on a sample without CONTACT, or on STROKE_START (which then starts the stroke).
        if latchedTools.contains(tool) {
            if wantsContact && !strokeStart {
                wantsContact = false
            } else {
                latchedTools.remove(tool)
            }
        }

        let point = PenPoint(x: sample.x, y: sample.y, pressure: wantsContact ? sample.pressure : 0,
                             tiltX: sample.tiltX, tiltY: sample.tiltY)

        guard inRange else {
            // PEN-7: IN_RANGE 1->0. Up first if touching, then leave. Nothing to do when already out of range.
            if let active = activePen {
                if active.contact {
                    out.append(.penUp(tool: active.tool, point.withPressure(0)))
                    if leftOwner == .pen { leftOwner = nil }
                }
                out.append(.penProximity(tool: active.tool, entering: false))
                activePen = nil
            }
            lastPenPoint = point
            return
        }

        // PEN-1: IN_RANGE 0->1 enters proximity with the tool's type. PEN-3: enter always precedes the down.
        if activePen == nil {
            out.append(.penProximity(tool: tool, entering: true))
            activePen = ActivePen(tool: tool, contact: false)
        }
        let wasInContact = activePen?.contact == true

        switch (wasInContact, wantsContact) {
        case (false, false):
            // PEN-6: in range, not touching: hover move.
            out.append(.penHover(tool: tool, point))
        case (false, true):
            // PEN-2: CONTACT 0->1. Pen priority (OWN-2): another owner of the left button is released first.
            takeLeftButtonForPen(into: &out)
            out.append(.penDown(tool: tool, point))
            activePen?.contact = true
        case (true, true):
            if strokeStart {
                // PEN-10: STROKE_START is the first sample of a contact. Seeing it while touching means a new
                // stroke: finish the old one so the app sees two separate strokes.
                out.append(.penUp(tool: tool, (lastPenPoint ?? point).withPressure(0)))
                out.append(.penDown(tool: tool, point))
            } else {
                // PEN-4: CONTACT 1->1.
                out.append(.penDrag(tool: tool, point))
            }
        case (true, false):
            // PEN-5: CONTACT 1->0. The sample's own position is where the pen lifted.
            out.append(.penUp(tool: tool, point.withPressure(0)))
            activePen?.contact = false
            if leftOwner == .pen { leftOwner = nil }
        }
        lastPenPoint = point
    }

    /// OWN-2: the pen always gets the left button. If a pointer source holds it, that source is released first
    /// (an `up` on its behalf); its own later release is then inert.
    private mutating func takeLeftButtonForPen(into out: inout [InjectAction]) {
        if let owner = leftOwner, owner != .pen {
            out.append(.mouseButton(.left, down: false))
        }
        leftOwner = .pen
    }

    /// Ends proximity for the active tool: up (if touching) at the last known point, then leave. Used by the
    /// watchdog, the tool-change rule and nothing else; PEN-7 and release-all have their own paths because they
    /// carry the position of the sample that caused them or a fixed order.
    mutating func closePen(into out: inout [InjectAction]) {
        guard let active = activePen else { return }
        if active.contact {
            out.append(.penUp(tool: active.tool, (lastPenPoint ?? Self.origin).withPressure(0)))
            if leftOwner == .pen { leftOwner = nil }
        }
        out.append(.penProximity(tool: active.tool, entering: false))
        activePen = nil
    }
}
