/// What a stopping pipeline does with its virtual displays (Codex review of T-237). A pipeline may hold two: the one
/// it runs (`current`) and one handed over by the previous pipeline or the parked slot (`inherited`) that its start
/// never consumed, because it failed before obtaining a display (an HDR10 encoder refusal, a missing permission).
/// Every display not handed on is released, so an owner's fallback never meets a still-alive display with the same
/// vendor/product/serial. Generic so it can be tested without the private API.
public enum DisplayTeardown {
    /// `keeping` (`stopKeepingDisplay`): the running display is handed on, or the unconsumed inherited one when none
    /// runs; anything else is released. Not keeping: all are released.
    public static func plan<D: AnyObject>(current: D?, inherited: D?, keeping: Bool) -> (keep: D?, release: [D]) {
        var all: [D] = []
        for d in [current, inherited].compactMap({ $0 }) where !all.contains(where: { $0 === d }) { all.append(d) }
        guard keeping, let keep = current ?? inherited else { return (nil, all) }
        return (keep, all.filter { $0 !== keep })
    }
}
