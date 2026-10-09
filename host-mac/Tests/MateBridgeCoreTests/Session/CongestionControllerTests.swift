import Testing
@testable import MateBridgeCore

private typealias CC = CongestionController

private let ceiling = 60_000
private let second: UInt64 = 1_000_000
private let ms: UInt64 = 1_000

private func controller(ceilingKbps: Int = ceiling, floorKbps: Int = CC.defaultFloorKbps) -> CC {
    CC(config: .init(ceilingKbps: ceilingKbps, floorKbps: floorKbps))
}

private func tick(_ nowUs: UInt64, srtt: UInt32 = 8, sb: UInt32 = 60_000, retx: UInt64 = 0) -> CC.Tick {
    CC.Tick(nowUs: nowUs, srttMs: srtt, sendBufferBytes: sb, retransmitPacketsDelta: retx)
}

/// 100 ms of video as the sender would have written it: six frames, `fraction` of the current target's rate.
private func feed(_ c: inout CC, fraction: Double = 1.0) {
    let bytes = Int(Double(c.targetKbps) * 12.5 * fraction)
    for _ in 0..<6 where bytes >= 6 { c.frameWritten(bytes: bytes / 6) }
}

/// Runs `seconds` of clean 100 ms ticks starting at `fromUs` and returns the end time. `demand`: the written video
/// rate as a fraction of the target (1 = a busy scene that fills it, small = a static screen).
@discardableResult
private func runClean(_ c: inout CC, fromUs: UInt64, seconds: Int, srtt: UInt32 = 8, demand: Double = 1.0) -> UInt64 {
    var t = fromUs
    for _ in 0..<(seconds * 10) {
        t += 100 * ms
        feed(&c, fraction: demand)
        c.tick(tick(t, srtt: srtt))
    }
    return t
}

@Suite struct CongestionControllerStepTests {
    /// A queueing-delay spike lowers the target on the very tick that shows it, and the climb back is no faster than
    /// the configured slope.
    @Test func spikeStepAndSlowRecovery() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 5)
        #expect(c.targetKbps == ceiling)

        t += 100 * ms
        let r1 = c.tick(tick(t, srtt: 80))
        #expect(r1 == .queueDelay)
        #expect(c.targetKbps == 42_000)

        // Quiet again (srtt back at the baseline): hold for the quiet period, then climb at the slope at most.
        let slopeKbpsPerSecond = Double(ceiling) * CC.upFractionPerSecond
        var previous = c.targetKbps
        var heldUntilQuiet = true
        var reachedCeilingAt: UInt64?
        let spikeEnd = t
        for _ in 0..<400 {
            t += 100 * ms
            feed(&c)  // a busy scene: the slope applies
            c.tick(tick(t))
            let now = c.targetKbps
            if t - spikeEnd < UInt64(CC.quietMs) * ms { heldUntilQuiet = heldUntilQuiet && now == previous }
            // 100 ms of slope plus one rounding step.
            #expect(Double(now - previous) <= slopeKbpsPerSecond * 0.1 + Double(CC.quantumKbps))
            if now == ceiling, reachedCeilingAt == nil { reachedCeilingAt = t }
            previous = now
        }
        #expect(heldUntilQuiet)
        let expectedSeconds = 2.0 + Double(ceiling - 42_000) / slopeKbpsPerSecond
        let took = Double(reachedCeilingAt.map { $0 - spikeEnd } ?? 0) / Double(second)
        #expect(abs(took - expectedSeconds) < 0.5)
    }

    @Test func boundsHoldUnderRepeatedTriggersAndLongQuiet() {
        var c = controller()
        var t: UInt64 = 0
        for i in 0..<300 {
            t += 100 * ms
            c.tick(tick(t, srtt: 90, retx: UInt64(i % 3)))
            c.queueDropped(nowUs: t)
            #expect(c.targetKbps >= CC.defaultFloorKbps && c.targetKbps <= ceiling)
        }
        #expect(c.targetKbps == CC.defaultFloorKbps)
        runClean(&c, fromUs: t, seconds: 120)
        #expect(c.targetKbps == ceiling)
    }

    @Test func ceilingBelowFloorDisablesControl() {
        var c = controller(ceilingKbps: 8_000)
        #expect(c.config.floorKbps == 8_000)
        c.queueDropped(nowUs: second)
        c.tick(tick(2 * second, srtt: 200, retx: 5))
        #expect(c.targetKbps == 8_000)
    }

    /// Constant RTT, with the 1 ms jitter of the srtt estimate and a healthy send buffer: nothing moves.
    @Test func constantRttDoesNotOscillate() {
        var c = controller()
        var t: UInt64 = 0
        var changes = 0
        var previous = c.targetKbps
        for i in 0..<1_800 {
            t += 100 * ms
            c.tick(tick(t, srtt: 8 + UInt32(i % 3), sb: 40_000 + UInt32(i % 7) * 10_000))
            if c.targetKbps != previous { changes += 1 }
            previous = c.targetKbps
        }
        #expect(changes == 0)
        #expect(c.targetKbps == ceiling)
    }

    /// A raised but stable RTT that is within the trigger margin is also left alone.
    @Test func smallRttRiseBelowMarginIsIgnored() {
        var c = controller()
        let t = runClean(&c, fromUs: 0, seconds: 5, srtt: 5)
        runClean(&c, fromUs: t, seconds: 20, srtt: 5 + CC.srttExcessTriggerMs - 1)
        #expect(c.targetKbps == ceiling)
    }

    /// A persistent RTT rise ends up as the new baseline once the old minima left the window.
    @Test func baselineFollowsAPersistentRise() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 5, srtt: 5)
        t = runClean(&c, fromUs: t, seconds: CC.baselineWindowSeconds + 25, srtt: 45)
        #expect(c.baselineSrttMs == 45)
        #expect(c.targetKbps == ceiling)
    }
}

@Suite struct CongestionControllerTriggerTests {
    @Test func retransmitDeltaLowersTargetOncePerInterval() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        t += 100 * ms
        let r2 = c.tick(tick(t, retx: 1))
        #expect(r2 == .retransmit)
        let afterFirst = c.targetKbps
        #expect(afterFirst < ceiling)
        // Within max(srtt, 250 ms) of the decrease: no second step.
        t += 100 * ms
        let r3 = c.tick(tick(t, retx: 4))
        #expect(r3 == nil)
        t += 100 * ms
        let r4 = c.tick(tick(t, retx: 1))
        #expect(r4 == nil)
        #expect(c.targetKbps == afterFirst)
        // A retransmit-free tick never lowers it.
        t += 100 * ms
        let r5 = c.tick(tick(t))
        #expect(r5 == nil)
    }

    @Test func largeSrttSetsTheMinimumStepInterval() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        t += 100 * ms
        let r6 = c.tick(tick(t, srtt: 600))
        #expect(r6 == .queueDelay)
        // 400 ms later is past the 250 ms floor but within one srtt of 600 ms.
        t += 400 * ms
        let r7 = c.tick(tick(t, srtt: 600))
        #expect(r7 == nil)
        t += 300 * ms
        let r8 = c.tick(tick(t, srtt: 600))
        #expect(r8 == .queueDelay)
    }

    @Test func queueDropsStepOncePerSrtt() {
        var c = controller()
        let t = runClean(&c, fromUs: 0, seconds: 3)
        let d9 = c.queueDropped(nowUs: t + 10 * ms)
        #expect(d9)
        let afterFirst = c.targetKbps
        #expect(afterFirst == 42_000)
        // A burst of drops inside one interval is one step.
        let d10 = c.queueDropped(nowUs: t + 12 * ms)
        #expect(!d10)
        let d11 = c.queueDropped(nowUs: t + 90 * ms)
        #expect(!d11)
        let d12 = c.queueDropped(nowUs: t + 200 * ms)
        #expect(!d12)
        #expect(c.targetKbps == afterFirst)
        // The next one after the interval steps again.
        let d13 = c.queueDropped(nowUs: t + 300 * ms)
        #expect(d13)
        #expect(c.targetKbps == 29_500 || c.targetKbps == 29_250 || c.targetKbps == 29_400)
    }

    /// A backlog over three budgets that lasts `sendBufferSustainMs` lowers the target; one reading, or a backlog that
    /// drains first, does not.
    @Test func sendBufferFarOverBudgetForLongLowersTarget() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        let limit = UInt32(CC.sendBufferTriggerFactor * c.budgetBytes)
        // At the threshold is not over it.
        t += 100 * ms
        #expect(c.tick(tick(t, sb: limit)) == nil)
        // Over it: 100, 200, 300 ms in nothing happens, at 400 ms it does.
        var results: [CC.Trigger?] = []
        for _ in 0..<5 {
            t += 100 * ms
            feed(&c)
            results.append(c.tick(tick(t, sb: limit + 1)))
        }
        #expect(results == [nil, nil, nil, nil, .sendBuffer])
        #expect(c.targetKbps < ceiling)
    }

    /// A 680 KB keyframe at 60 Mbps: the send buffer is read over the limit once, then it drains in about 90 ms.
    @Test func oneKeyframeBurstInTheSendBufferIsNotCongestion() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        for sb in [680_000, 60_000, 40_000, 60_000] as [UInt32] {
            t += 100 * ms
            feed(&c)
            #expect(c.tick(tick(t, sb: sb)) == nil)
        }
        #expect(c.targetKbps == ceiling)
        // Even three readings in a row (a keyframe that drains slower than a 60 Mbps link would) are under 400 ms.
        for _ in 0..<3 {
            t += 100 * ms
            feed(&c)
            #expect(c.tick(tick(t, sb: 680_000)) == nil)
        }
        t += 100 * ms
        #expect(c.tick(tick(t, sb: 100_000)) == nil)
        #expect(c.targetKbps == ceiling)
    }

    /// The over-limit streak is broken by any reading below it, and its length is time: 1 s ticks need the second one.
    @Test func sendBufferStreakNeedsConsecutiveReadingsAcrossTheSustainTime() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        t += second
        #expect(c.tick(tick(t, sb: 700_000)) == nil)
        t += second
        #expect(c.tick(tick(t, sb: 700_000)) == .sendBuffer)

        var d = controller()
        t = runClean(&d, fromUs: 0, seconds: 3)
        for _ in 0..<8 {
            t += 300 * ms
            feed(&d)
            #expect(d.tick(tick(t, sb: 700_000)) == nil)
            t += 100 * ms
            feed(&d)
            #expect(d.tick(tick(t, sb: 10_000)) == nil)  // breaks the streak
        }
        #expect(d.targetKbps == ceiling, "over, below, over, below never adds up to 400 ms in a row")
    }

    @Test func triggerInsideTheIntervalStillRestartsTheQuietPeriod() {
        var c = controller()
        var t = runClean(&c, fromUs: 0, seconds: 3)
        c.queueDropped(nowUs: t)
        let low = c.targetKbps
        // A coalesced trigger 200 ms later postpones the climb to 2 s after it.
        c.queueDropped(nowUs: t + 200 * ms)
        t += 200 * ms
        for _ in 0..<19 {
            t += 100 * ms
            feed(&c)
            c.tick(tick(t))
        }
        #expect(c.targetKbps == low)
        runClean(&c, fromUs: t, seconds: 3)
        #expect(c.targetKbps > low)
    }

    @Test func tcpInfoReportBridge() {
        let snap = TcpConnectionSnapshot(srttMs: 12, sendBufferBytes: 99, retransmitPackets: 7)
        var meter = TcpInfoMeter()
        let report = meter.take(snap)
        let tick = CC.Tick(nowUs: 5, report: report)
        #expect(tick.srttMs == 12 && tick.sendBufferBytes == 99 && tick.retransmitPacketsDelta == 7)
    }
}

@Suite struct CongestionControllerRecoveryTests {
    /// Cuts the target to the floor with queue drops and returns the time of the last trigger.
    private func cutToFloor(_ c: inout CC) -> UInt64 {
        var t = runClean(&c, fromUs: 0, seconds: 3)
        for _ in 0..<10 {
            t += 300 * ms
            feed(&c)
            c.queueDropped(nowUs: t)
        }
        #expect(c.targetKbps == CC.defaultFloorKbps)
        return t
    }

    /// Static text: tiny frames. The last trigger is followed by the quiet period; the first full demand window after
    /// it shows almost no traffic, and the target is back at the ceiling by 5 s, not after the 16 s slope.
    @Test func staticSceneJumpsToTheCeilingWithinFiveSeconds() {
        var c = controller()
        let lastTrigger = cutToFloor(&c)
        var t = lastTrigger
        var reachedAt: UInt64?
        for _ in 0..<100 {
            t += 100 * ms
            feed(&c, fraction: 0.02)  // 2 % of the floor: a still screen
            c.tick(tick(t))
            if c.targetKbps == ceiling, reachedAt == nil { reachedAt = t - lastTrigger }
        }
        let took = Double(reachedAt ?? UInt64.max) / Double(second)
        #expect(took >= Double(CC.quietMs) / 1_000, "never before the quiet period is over")
        #expect(took <= 5)
    }

    /// A busy scene keeps the slope: no jump, the rise per second stays at the configured fraction of the ceiling.
    @Test func busySceneKeepsTheSlope() {
        var c = controller()
        let lastTrigger = cutToFloor(&c)
        var t = lastTrigger
        var previous = c.targetKbps
        let slope = Double(ceiling) * CC.upFractionPerSecond
        for _ in 0..<100 {
            t += 100 * ms
            feed(&c, fraction: 0.9)
            c.tick(tick(t))
            #expect(Double(c.targetKbps - previous) <= slope * 0.1 + Double(CC.quantumKbps))
            previous = c.targetKbps
        }
        // 10 s after the cut: 8 s of slope above the floor, nowhere near the ceiling.
        #expect(c.targetKbps < ceiling)
        #expect(c.targetKbps > CC.defaultFloorKbps)
    }

    /// Written bytes that are low because the owner's gate was refusing are not a still screen.
    @Test func demandIsNotTrustedWhileTheGateRefuses() {
        var c = controller()
        let lastTrigger = cutToFloor(&c)
        var t = lastTrigger
        for _ in 0..<50 {
            t += 100 * ms
            feed(&c, fraction: 0.02)
            c.tick(CC.Tick(nowUs: t, srttMs: 8, sendBufferBytes: 60_000, retransmitPacketsDelta: 0, gateRefused: true))
        }
        #expect(c.targetKbps < ceiling, "slope only: 5 s after the cut it is at most 12 + 3 s of slope")
    }

    /// A trigger in the demand window postpones the jump: it is judged by what happens after the last trigger.
    @Test func aNewTriggerRestartsTheQuietPeriodBeforeTheJump() {
        var c = controller()
        var t = cutToFloor(&c)
        for _ in 0..<15 {
            t += 100 * ms
            feed(&c, fraction: 0.02)
            c.tick(tick(t))
        }
        c.queueDropped(nowUs: t)
        let after = c.targetKbps
        for _ in 0..<19 {
            t += 100 * ms
            feed(&c, fraction: 0.02)
            c.tick(tick(t))
        }
        #expect(c.targetKbps == after, "held for the quiet period after the new trigger")
    }
}

@Suite struct CongestionControllerAdmissionTests {
    @Test func budgetIsTwentyMillisecondsOfTheTarget() {
        let c = controller()
        // 60 Mbps = 7.5 MB/s -> 150 KB per 20 ms; one 125 KB average frame is below that.
        #expect(c.budgetBytes == 150_000)
        #expect(c.mayWrite(sendBufferBytes: 150_000))
        #expect(!c.mayWrite(sendBufferBytes: 150_001))
        #expect(c.mayWrite(sendBufferBytes: 0))
    }

    @Test func budgetNeverDropsBelowOneAverageFrame() {
        var c = controller()
        // Keyframe-heavy traffic at the floor: the average frame is 80 KB, the 20 ms budget at 12 Mbps only 30 KB.
        for _ in 0..<200 { c.frameWritten(bytes: 80_000) }
        for i in 0..<30 { c.queueDropped(nowUs: UInt64(i) * second) }
        #expect(c.targetKbps == CC.defaultFloorKbps)
        #expect(c.budgetBytes >= 79_000)
        #expect(c.mayWrite(sendBufferBytes: 79_000))
    }

    @Test func budgetFollowsTheTarget() {
        var c = controller()
        let full = c.budgetBytes
        c.queueDropped(nowUs: second)
        #expect(c.budgetBytes < full)
    }

    @Test func frameWriteIgnoresEmptyAndTracksAverage() {
        var c = controller()
        let before = c.budgetBytes
        c.frameWritten(bytes: 0)
        #expect(c.budgetBytes == before)
        for _ in 0..<300 { c.frameWritten(bytes: 400_000) }
        #expect(c.budgetBytes >= 399_000)
    }

    @Test func timeGoingBackwardsIsHarmless() {
        var c = controller()
        c.tick(tick(10 * second))
        c.queueDropped(nowUs: 11 * second)
        let low = c.targetKbps
        c.tick(tick(5 * second, retx: 3))
        #expect(c.targetKbps <= low)
        #expect(c.targetKbps >= CC.defaultFloorKbps)
    }
}

@Suite struct CongestionControllerReplayTests {
    /// Replays the numbers-only 2026-10-09 Oyun trace (1 s resolution, open loop) and returns the target after each
    /// second.
    static func replay() -> (targets: [Int], decreased: [Bool]) {
        var c = controller(ceilingKbps: CongestionReplayTrace.ceilingKbps)
        var out: [Int] = []
        var decreased: [Bool] = []
        var lastFrames = 0
        var lastBytes = 0
        for (i, row) in CongestionReplayTrace.rows.enumerated() {
            let t = UInt64(i + 1) * second
            // The written demand of the second: every frame of the stats line, the previous line's rate when none fell
            // into this second.
            if row.sentFrames > 0 {
                lastFrames = row.sentFrames
                lastBytes = row.sentKbps * 125 / row.sentFrames
            }
            for _ in 0..<lastFrames { c.frameWritten(bytes: lastBytes) }
            // The cadence window of `queueDrops` ended about 0.6 s before the tcp tick.
            var down = false
            if row.queueDrops > 0 { down = c.queueDropped(nowUs: t - 600 * ms) }
            let reason = c.tick(CC.Tick(nowUs: t, srttMs: row.srttMs, sendBufferBytes: row.sendBufferBytes,
                                        retransmitPacketsDelta: row.retransmitPackets))
            out.append(c.targetKbps)
            decreased.append(down || reason != nil)
        }
        return (out, decreased)
    }

    /// The target after each second of the trace (ceiling 60 000 kbps, floor 12 000), stored from the first accepted run; re-recorded by T-328 (sustained send-buffer trigger, idle recovery, per-frame demand in the replay).
    /// A change to a constant of `CongestionController` shows up here; re-record it deliberately.
    static let expectedTargets: [Int] = [
        60000, 29500, 20500, 14500, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 12000, 12000,  // 0
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 42000, 42000, 42000, 45000, 48000, 60000, 60000, 60000,  // 15
        60000, 60000, 60000, 60000, 60000, 60000, 42000, 29500, 29500, 26500, 26500, 26500, 29500, 29250, 29250,  // 30
        26250, 23750, 16500, 12000, 12000, 13750, 16750, 17750, 12000, 12000, 12000, 13750, 16750, 19750, 22750,  // 45
        25750, 28750, 31750, 34750, 37750, 40750, 43750, 46750, 49750, 60000, 60000, 60000, 60000, 60000, 60000,  // 60
        60000, 60000, 60000, 54000, 54000, 54000, 57000, 60000, 42000, 42000, 43750, 46750, 49750, 52750, 55750,  // 75
        58750, 60000, 54000, 54000, 54000, 57000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 90
        60000, 60000, 60000, 60000, 54000, 54000, 54000, 57000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 105
        60000, 60000, 60000, 60000, 60000, 60000, 54000, 54000, 54000, 57000, 60000, 60000, 60000, 60000, 60000,  // 120
        60000, 60000, 60000, 60000, 54000, 54000, 54000, 57000, 60000, 60000, 60000, 54000, 54000, 54000, 51250,  // 135
        51250, 51250, 54250, 57250, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 150
        60000, 60000, 60000, 60000, 54000, 54000, 48500, 48500, 43750, 43750, 43750, 46750, 49750, 52750, 55750,  // 165
        58750, 60000, 60000, 60000, 60000, 60000, 54000, 54000, 54000, 57000, 60000, 54000, 48500, 48500, 43750,  // 180
        43750, 39250, 35500, 35500, 32000, 28750, 28750, 28750, 31750, 34750, 37750, 40750, 39250, 39250, 39250,  // 195
        42250, 45250, 48250, 46250, 46250, 46250, 49250, 52250, 55250, 58250, 60000, 60000, 60000, 60000, 60000,  // 210
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 225
        60000, 60000, 60000, 60000, 60000, 54000, 48500, 34000, 23750, 23750, 23000, 23000, 20750, 13000, 12000,  // 240
        12000, 13750, 16750, 19750, 22750, 25750, 28750, 31750, 34750, 37750, 40750, 43750, 46750, 49750, 52750,  // 255
        55750, 58750, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 270
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 285
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 300
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 315
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 54000, 54000, 48500, 48500, 60000, 60000, 60000,  // 330
        60000, 60000, 60000, 60000, 54000, 54000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 54000, 54000,  // 345
        48500, 48500, 60000, 60000, 60000, 60000, 60000, 54000, 54000, 60000, 60000, 60000, 60000, 60000, 60000,  // 360
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 375
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 390
        60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000, 60000,  // 405,
    ]

    /// The seconds with a host queue-drop burst of 9: tablet 16:51:00, 16:54:19 and 16:54:26.
    static let dropMoments = [47, 247, 254]

    @Test func goldenTargetSequence() {
        #expect(CongestionReplayTrace.rows.count == Self.expectedTargets.count)
        #expect(Self.replay().targets == Self.expectedTargets)
    }

    @Test func targetStaysInsideTheBounds() {
        for target in Self.replay().targets {
            #expect(target >= CC.defaultFloorKbps && target <= CongestionReplayTrace.ceilingKbps)
        }
    }

    /// At each queue-drop burst the controller steps down within a second of it and ends up at 70 % of the ceiling or
    /// lower; the bitrate at the burst is below what it was before the preceding quiet stretch.
    @Test func targetFallsAtTheQueueDropMoments() {
        let r = Self.replay()
        for i in Self.dropMoments {
            #expect(CongestionReplayTrace.rows[i].queueDrops == 9)
            #expect(r.decreased[i], "no decrease at second \(i)")
            #expect(r.targets[i] <= CongestionReplayTrace.ceilingKbps * 7 / 10, "second \(i): \(r.targets[i])")
            #expect(r.targets[i] < r.targets[i - 2], "second \(i) did not fall")
        }
    }

    /// The 385-packet retransmit burst of the game start and its srtt/queue-drop surroundings lower the target.
    @Test func targetFallsOnTheGameStart() {
        let r = Self.replay()
        #expect(CongestionReplayTrace.rows[22].retransmitPackets == 385)
        #expect(r.decreased[22])
        #expect(r.targets[22] < r.targets[21] || r.targets[21] < CongestionReplayTrace.ceilingKbps)
        #expect(r.targets[1...12].allSatisfy { $0 <= 30_000 })
    }

    /// The last 60 s of the trace have no queue drops; the target is back at the ceiling well before the end and stays.
    @Test func targetReturnsToTheCeilingInTheLastQuietMinute() {
        let rows = CongestionReplayTrace.rows
        let r = Self.replay()
        let lastDrop = rows.lastIndex { $0.queueDrops > 0 }!
        #expect(rows.count - lastDrop > 60)
        let tail = r.targets[(rows.count - 60)...]
        #expect(tail.last == CongestionReplayTrace.ceilingKbps)
        #expect(tail.suffix(30).allSatisfy { $0 == CongestionReplayTrace.ceilingKbps })
        #expect(r.targets[(lastDrop + 30)...].contains(CongestionReplayTrace.ceilingKbps))
    }

    /// Lone 1-3 packet retransmits at a healthy RTT cost 10 % at most, never more.
    @Test func loneRetransmitsAreMild() {
        let r = Self.replay()
        let rows = CongestionReplayTrace.rows
        var seen = 0
        for i in 100..<340 where rows[i].retransmitPackets > 0 && rows[i].retransmitPackets < 4
            && rows[i].queueDrops == 0 && r.targets[i - 1] == CongestionReplayTrace.ceilingKbps {
            seen += 1
            #expect(r.targets[i] >= CongestionReplayTrace.ceilingKbps * 9 / 10)
        }
        #expect(seen >= 3)
    }
}
