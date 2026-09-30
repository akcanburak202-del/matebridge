// Scroll part of the input state machine (PROTOCOL.md section 4 SCROLL host rules, section 7 scroll watchdog).

extension InputStateMachine {
    mutating func handleScroll(_ m: Scroll, now: UInt64) -> [InjectAction] {
        switch m.phase {
        case .none:
            // SCROLL-4: a wheel step is a single event and touches no gesture state.
            return [.scrollWheel(dx: m.dx, dy: m.dy)]
        case .began:
            // SCROLL-3: a BEGAN over an open gesture first ends the old one (forced end, no momentum).
            var out: [InjectAction] = []
            if scrollOpen { out.append(.scroll(.forcedEnd, dx: 0, dy: 0)) }
            scrollOpen = true
            lastScrollAt = now
            out.append(.scroll(.began, dx: m.dx, dy: m.dy))
            return out
        case .changed:
            // SCROLL-2: CHANGED without BEGAN is ignored.
            guard scrollOpen else { return [] }
            lastScrollAt = now
            return [.scroll(.changed, dx: m.dx, dy: m.dy)]
        case .ended:
            guard scrollOpen else { return [] }
            scrollOpen = false
            return [.scroll(.ended, dx: m.dx, dy: m.dy)]
        case .cancelled:
            guard scrollOpen else { return [] }
            scrollOpen = false
            return [.scroll(.cancelled, dx: m.dx, dy: m.dy)]
        }
    }
}
