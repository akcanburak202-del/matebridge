package dev.matebridge.client.video

import dev.matebridge.client.protocol.Bytes
import dev.matebridge.client.protocol.StreamConfig
import dev.matebridge.client.protocol.VideoFrame
import dev.matebridge.client.video.HealthEvent.Detached
import dev.matebridge.client.video.HealthEvent.Exited
import dev.matebridge.client.video.HealthEvent.Fault
import dev.matebridge.client.video.HealthEvent.FirstOutput
import dev.matebridge.client.video.HealthEvent.Generation
import dev.matebridge.client.video.HealthEvent.Running
import dev.matebridge.client.video.VideoHealth.Action
import dev.matebridge.client.video.VideoHealth.State
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** T-159 (decision 0019): video health state, rules, recovery ladder, renderer generations and the debug fault. */
class VideoHealthTest {
    private var now = 100_000L
    private val logs = ArrayList<String>()
    private var changes = 0
    private val health = VideoHealth({ now }, log = { level, ev, f -> logs.add("$level $ev $f") }, onChange = { changes++ })
    private val progress = DecodeProgress()

    private fun begin(gen: Int, running: Boolean = true) {
        progress.begin(gen)
        health.onEvent(Generation(gen))
        if (running) health.onEvent(Running(gen))
    }

    private fun healthy(gen: Int) {
        begin(gen)
        progress.onInput(gen, now)
        assertTrue(progress.onOutput(gen))
        health.onEvent(FirstOutput(gen))
        assertEquals(State.HEALTHY, health.state)
    }

    private fun tick(): Action? = health.tick(progress.snapshot())

    private fun inputs(gen: Int, n: Int, stepMs: Long = 0) = repeat(n) { if (it > 0) now += stepMs; progress.onInput(gen, now) }

    // ---- state machine and rules ----

    @Test fun aGenerationIsStartingWithInputClosedUntilItsFirstOutput() {
        assertEquals(State.IDLE, health.state)
        assertFalse(health.inputAllowed)
        begin(1)
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        assertNull(tick())
        assertEquals(State.STARTING, health.state)
        health.onEvent(FirstOutput(1))
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
        assertTrue(logs.toString(), "I video_health state=starting cause=- from=idle vgen=1" in logs)
        assertTrue(logs.toString(), "I video_health state=healthy cause=- from=starting vgen=1" in logs)
    }

    @Test fun giveUpFaultsAndStopsFeedingAndKeyframeRetries() {
        healthy(1)
        assertTrue(health.feedAllowed && health.keyframeRetriesAllowed)
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.GIVE_UP, health.cause)
        assertFalse(health.inputAllowed)
        assertFalse(health.feedAllowed)
        assertFalse(health.keyframeRetriesAllowed)
        assertTrue(health.showOverlay)
        assertTrue(logs.toString(), "W video_health state=fault cause=give_up from=healthy vgen=1" in logs)
        // Still FAULT a minute later with the fake clock: nothing re-enables feeding inside the generation.
        repeat(120) { now += 500; tick(); assertFalse(health.feedAllowed); assertFalse(health.keyframeRetriesAllowed) }
    }

    @Test fun noOutputNeedsThreePendingInputsWithTheOldestQueued1500msAgo() {
        healthy(1)
        inputs(1, 2)
        now += 60_000
        tick()
        assertEquals("two pending inputs never fault", State.HEALTHY, health.state)

        progress.onOutput(1)
        inputs(1, 3, stepMs = 10) // oldest at t, newest at t + 20
        now += 1499 - 20
        tick()
        assertEquals(State.HEALTHY, health.state)
        now += 1
        tick()
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.NO_OUTPUT, health.cause)
        assertTrue(logs.toString(), logs.any { it.contains("state=fault cause=no_output") })
    }

    @Test fun idleScreenThenABurstDoesNotFaultWhileItsFirstOutputIsPending() {
        healthy(1)
        now += 10_000 // static screen: nothing queued, nothing decoded
        tick()
        inputs(1, 3, stepMs = 15) // the user starts drawing: 3 inputs within 30 ms
        tick()
        now += 20
        progress.onOutput(1)
        tick()
        now += 5_000
        tick()
        assertEquals(State.HEALTHY, health.state)

        inputs(1, 3, stepMs = 15)
        now += 1500 - 30
        tick()
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.NO_OUTPUT, health.cause)
    }

    @Test fun aStaticScreenStaysHealthyIndefinitely() {
        healthy(1)
        repeat(1200) { now += 500; assertNull(tick()) } // 10 minutes without a frame
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
    }

    @Test fun decoderThreadNotRunningTwoSecondsAfterTheGenerationBeganFaults() {
        begin(1, running = false)
        now += 1999
        tick()
        assertEquals(State.STARTING, health.state)
        now += 1
        tick()
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.NOT_RUNNING, health.cause)

        // A thread that starts late (within 2 s) is fine; one that exits while attached faults on the next tick.
        begin(2, running = false)
        now += 1500
        health.onEvent(Running(2))
        now += 1000
        tick()
        assertEquals(State.STARTING, health.state)
        health.onEvent(FirstOutput(2))
        health.onEvent(Exited(2))
        tick()
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.NOT_RUNNING, health.cause)
    }

    @Test fun everyCauseGoesThroughTheGenericFaultInput() {
        for (cause in FaultCause.values()) {
            val lines = ArrayList<String>()
            val h = VideoHealth({ now }, log = { _, ev, f -> lines.add("$ev $f") })
            h.onEvent(Generation(7)); h.onEvent(Running(7)); h.onEvent(FirstOutput(7))
            if (cause == FaultCause.STUCK) h.fault(cause) else h.onEvent(Fault(7, cause))
            assertEquals(State.FAULT, h.state)
            assertEquals(cause, h.cause)
            assertTrue(lines.toString(), "video_health state=fault cause=${cause.logName} from=healthy vgen=7" in lines)
        }
        assertEquals(listOf("give_up", "no_output", "not_running", "stuck", "video_lost"), FaultCause.values().map { it.logName })
    }

    @Test fun eventsOfARetiredGenerationAreIgnored() {
        healthy(1)
        begin(2)
        assertEquals(State.STARTING, health.state)
        health.onEvent(FirstOutput(1)) // a late output of the old codec
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        health.onEvent(Exited(1))
        health.onEvent(Detached(1))
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        progress.onInput(1, now); progress.onInput(1, now); progress.onInput(1, now) // stale progress, too
        now += 5_000
        assertNull(tick())
        assertEquals(State.STARTING, health.state)
        health.onEvent(FirstOutput(2))
        assertEquals(State.HEALTHY, health.state)
    }

    @Test fun leavingFaultNeedsANewGenerationAndItsFirstOutput() {
        healthy(1)
        inputs(1, 3)
        now += 1500
        tick()
        assertEquals(State.FAULT, health.state)
        // The faulted generation may still decode something: input stays closed.
        progress.onOutput(1)
        health.onEvent(FirstOutput(1))
        tick()
        assertEquals(State.FAULT, health.state)
        assertFalse(health.inputAllowed)
        begin(2)
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        assertTrue(health.feedAllowed) // the new generation must get frames to produce its first output
        health.onEvent(FirstOutput(2))
        assertTrue(health.inputAllowed)
    }

    @Test fun reconnectAndMigrationCloseInputUntilTheNewGenerationsFirstOutput() {
        healthy(1)
        // Automatic reconnect: releaseRenderer() -> detach, then the next STREAM_CONFIG attaches again. The session's
        // frame counter is not involved; only the generation matters.
        health.onEvent(Detached(1))
        assertEquals(State.IDLE, health.state)
        assertFalse(health.inputAllowed)
        assertFalse(health.showOverlay)
        begin(2)
        assertFalse(health.inputAllowed)
        health.onEvent(FirstOutput(2))
        assertTrue(health.inputAllowed)
        // USB <-> Wi-Fi migration: the new session's STREAM_CONFIG runs reconfigure() on the attached surface.
        begin(3)
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        assertTrue(logs.toString(), "I video_health state=starting cause=- from=healthy vgen=3" in logs)
        health.onEvent(FirstOutput(3))
        assertTrue(health.inputAllowed)
    }

    // ---- T-218: video connection loss ----

    /** The session's current video connection generation (rises with every connection). */
    private var conn = 100
    private fun lost(quiet: Boolean = false) = health.videoLost(conn, quietOverlay = quiet)
    /** A new video connection delivered its first frame. */
    private fun flowing(): Action? = health.videoFlowing(++conn)

    @Test fun videoLossClosesInputInTheSameCallAndShowsTheOverlay() {
        healthy(1)
        val before = changes
        lost()
        assertEquals(State.FAULT, health.state)
        assertEquals(FaultCause.VIDEO_LOST, health.cause)
        assertFalse(health.inputAllowed)
        assertTrue("the activity closes capture (RELEASE_ALL(USER)) on this change", changes > before)
        assertTrue(health.showOverlay)
        assertFalse(health.feedAllowed)
        assertTrue(logs.toString(), "W video_health state=fault cause=video_lost from=healthy vgen=1" in logs)
        // A second report (another failed reconnect) changes nothing.
        val again = changes
        lost()
        assertEquals(again, changes)
    }

    @Test fun aLostVideoKeepsInputClosedAndTheOverlayWhileItStaysAway() {
        healthy(1)
        lost()
        // The decoder still holds the last picture and may even decode one late frame of the old connection.
        progress.onOutput(1)
        health.onEvent(FirstOutput(1))
        val actions = ArrayList<Action?>()
        repeat(120) { // 60 s: control PONGs go on (nothing here depends on them), the video never comes back
            now += 500
            val a = tick()
            actions += a
            when (a) {
                Action.RESTART_CODEC -> begin(health.generation + 1) // no frames arrive: the new generation stays STARTING
                Action.RECONNECT -> { health.onEvent(Detached(health.generation)); begin(health.generation + 1) }
                null -> Unit
            }
            assertFalse("input stays closed at ${it * 500} ms", health.inputAllowed)
            assertTrue("overlay stays up at ${it * 500} ms", health.showOverlay)
            conn++; lost() // every failed video reconnect reports again
        }
        assertEquals(listOf(Action.RESTART_CODEC, Action.RESTART_CODEC, Action.RECONNECT), actions.filterNotNull())
        assertTrue(health.manual)
    }

    @Test fun freshVideoAfterALossRestartsTheCodecAndReopensOnlyAtTheNewGenerationsOutput() {
        healthy(1)
        lost()
        now += 600 // the session reconnects the video after 500 ms
        assertEquals(Action.RESTART_CODEC, flowing())
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=resume ") })
        begin(2) // MainActivity: renderer.restartCodec() -> a new generation
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        assertTrue(health.feedAllowed)
        // A late output of the old generation does not count.
        health.onEvent(FirstOutput(1))
        assertFalse(health.inputAllowed)
        // The ladder keeps its own schedule (+1 s after the loss); the resumed generation decodes before it.
        now += 300
        assertNull(tick())
        progress.onInput(2, now)
        assertTrue(progress.onOutput(2))
        health.onEvent(FirstOutput(2))
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
        assertFalse(health.showOverlay)
        // A later first frame of yet another connection does nothing while the video is fine.
        assertNull(flowing())
    }

    /**
     * Review P2: every reconnect (every 500 ms) gets a first frame (e.g. CODEC_CONFIG) and closes before any decoded
     * output. The resumes are bounded and never move the ladder: restart +1 s, restart +3 s, reconnect +6 s, manual +15 s.
     */
    @Test fun partialReconnectsKeepTheLadderOnScheduleAndBoundTheResumes() {
        healthy(1)
        val t0 = now
        lost()
        val ladder = ArrayList<Pair<Long, Action>>()
        var resumes = 0
        var manualResumes = 0
        var manualAt = -1L
        repeat(120) { // 60 s
            now += 500
            when (val a = tick()) {
                Action.RESTART_CODEC -> { ladder += (now - t0) to a; begin(health.generation + 1) }
                Action.RECONNECT -> {
                    ladder += (now - t0) to a
                    health.onEvent(Detached(health.generation))
                    begin(health.generation + 1)
                }
                null -> Unit
            }
            if (health.manual && manualAt < 0) manualAt = now - t0
            val wasManual = health.manual
            if (flowing() == Action.RESTART_CODEC) {
                if (wasManual) manualResumes++ else resumes++
                begin(health.generation + 1)
            }
            assertFalse(health.inputAllowed)
            lost() // the connection drops before any decoded output
        }
        assertEquals(
            listOf(1000L to Action.RESTART_CODEC, 3000L to Action.RESTART_CODEC, 6000L to Action.RECONNECT),
            ladder,
        )
        assertEquals(15_000L, manualAt)
        assertEquals(VideoHealth.MAX_RESUMES, resumes)
        // T-294: past manual (15 s .. 60 s) one resume per 10 s at most.
        assertTrue("manual resumes $manualResumes", manualResumes in 3..5)
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=resume_skipped ") })
    }

    private fun toManual() {
        healthy(1)
        lost()
        repeat(40) { // 20 s: the ladder runs to manual, the video never comes back
            now += 500
            when (tick()) {
                Action.RESTART_CODEC -> begin(health.generation + 1)
                Action.RECONNECT -> { health.onEvent(Detached(health.generation)); begin(health.generation + 1) }
                null -> Unit
            }
            conn++; lost()
        }
        assertTrue(health.manual)
    }

    /** T-294: manual state, host serves video again: the codec restarts without "Yeniden dene", then the layer lifts. */
    @Test fun manualStateResumesWhenVideoReturnsThenTheLayerLiftsAndTheEpisodeEnds() {
        toManual()
        assertTrue(health.showOverlay)
        assertEquals(Action.RESTART_CODEC, flowing())
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=manual_resume ") })
        val gen = health.generation + 1
        begin(gen) // the resume starts a new generation
        assertEquals(State.STARTING, health.state)
        assertFalse("input stays closed until the first decoded output", health.inputAllowed)
        progress.onInput(gen, now)
        assertTrue(progress.onOutput(gen))
        health.onEvent(FirstOutput(gen))
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
        assertFalse("the layer lifts", health.showOverlay)
        now += 10_000
        assertNull(tick())
        assertFalse(health.recovering)
        assertFalse(health.manual)
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=done ") })
    }

    @Test fun manualResumeIsRateLimitedToOncePerTenSeconds() {
        toManual()
        assertEquals(Action.RESTART_CODEC, flowing())
        begin(health.generation + 1)
        conn++; lost() // half-working connection: a frame, then it drops before any output
        now += 9_900
        assertNull(flowing())
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=resume_skipped ") && "manual=1" in it })
        conn++; lost()
        now += 200 // 10.1 s after the first manual resume
        assertEquals(Action.RESTART_CODEC, flowing())
        assertEquals(2, logs.count { it.startsWith("I video_recover step=manual_resume ") })
    }

    @Test fun staleConnectionIsStillIgnoredInManual() {
        toManual()
        assertNull(health.videoFlowing(conn)) // not newer than the last lost connection
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=resume_stale ") })
        assertTrue(logs.none { it.startsWith("I video_recover step=manual_resume ") })
    }

    @Test fun aStaleFirstFrameNoticeOfAReplacedConnectionIsDropped() {
        healthy(1)
        health.videoLost(7) // connection 7 (which replaced 5) failed
        assertNull(health.videoFlowing(5)) // connection 5's late notice
        assertNull(health.videoFlowing(7))
        assertEquals(State.FAULT, health.state)
        assertTrue(logs.toString(), logs.any { it.startsWith("I video_recover step=resume_stale conn=5 lost_conn=7") })
        assertEquals(Action.RESTART_CODEC, health.videoFlowing(9))
    }

    @Test fun videoFlowingRestartsOnlyAfterAVideoLossFault() {
        assertNull(flowing()) // no surface
        begin(1)
        assertNull(flowing()) // STARTING: it is fed already
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        assertNull("a decoder fault keeps its own recovery", flowing())
        begin(2)
        lost()
        assertEquals(State.FAULT, health.state)
        assertEquals(Action.RESTART_CODEC, flowing())
    }

    @Test fun aLossDuringAMigrationGatesInputAtOnceButHoldsTheOverlayUntilTheFirstStep() {
        healthy(1)
        val before = changes
        lost(quiet = true)
        assertEquals(State.FAULT, health.state)
        assertFalse("input is gated exactly as for any loss", health.inputAllowed)
        assertTrue(changes > before)
        assertFalse(health.feedAllowed)
        assertFalse(health.showOverlay)
        now += 500
        assertNull(tick())
        assertFalse(health.showOverlay)
        now += 500
        assertEquals("the ladder runs as usual", Action.RESTART_CODEC, tick())
        assertTrue("still broken at the first step: the overlay shows", health.showOverlay)
        begin(2)
        assertTrue(health.showOverlay) // recovering and STARTING
    }

    @Test fun aPromotionThatReconfiguresInTimeNeverShowsTheOverlay() {
        healthy(1)
        lost(quiet = true)
        now += 200
        begin(2) // the promotion's STREAM_CONFIG reconfigures
        assertFalse(health.inputAllowed)
        assertFalse(health.showOverlay)
        now += 300
        assertNull(tick())
        health.onEvent(FirstOutput(2))
        assertTrue(health.inputAllowed)
        assertFalse(health.showOverlay)
        // A later loss outside a migration shows it at once.
        lost()
        assertTrue(health.showOverlay)
    }

    @Test fun aLossOutsideAMigrationOrAnotherFaultEndsTheQuietOverlay() {
        healthy(1)
        lost(quiet = true)
        assertFalse(health.showOverlay)
        val before = changes
        lost() // the next video connection failed after the proof was over
        assertTrue(health.showOverlay)
        assertTrue(changes > before)
    }

    @Test fun anotherFaultOfThePromotedGenerationShowsTheOverlayAtOnce() {
        healthy(1)
        lost(quiet = true)
        begin(2, running = false) // the promotion reconfigures, but its decoder thread never runs
        assertFalse(health.showOverlay)
        now += 2000
        tick()
        assertEquals(FaultCause.NOT_RUNNING, health.cause)
        assertTrue(health.showOverlay)
    }

    @Test fun aQuietLossInsideAnOpenEpisodeKeepsTheOverlay() {
        healthy(1)
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        healthy(2) // recovered, but the episode is still open (< 10 s healthy)
        lost(quiet = true)
        assertTrue("an overlay already in an episode is never hidden", health.showOverlay)
    }

    @Test fun videoLossWithoutASurfaceDoesNothing() {
        lost()
        assertEquals(State.IDLE, health.state)
        assertFalse(health.showOverlay)
        assertEquals(0, changes)
    }

    @Test fun aStaticDesktopWithALiveVideoConnectionNeverFaults() {
        healthy(1)
        // No frames and no video_lost report (the connection is intact; keepalive probes are answered by the kernel).
        repeat(1200) { now += 500; assertNull(tick()) }
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
        assertFalse(health.showOverlay)
        assertNull(flowing()) // a reconnect without a loss changes nothing
    }

    // ---- recovery ladder ----

    @Test fun recoveryStepsAreBoundedAndOrdered() {
        healthy(1)
        val t0 = now
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        val actions = ArrayList<Pair<Long, Action>>()
        var gen = 1
        // Every step's restart gives a generation that never produces output (it stays STARTING).
        while (now - t0 <= 600_000) {
            tick()?.let { a ->
                actions.add((now - t0) to a)
                when (a) {
                    Action.RESTART_CODEC -> begin(++gen)
                    Action.RECONNECT -> { // the session drops, the surface is released and attached again 2 s later
                        health.onEvent(Detached(gen))
                        now += 2_000
                        assertNull(tick()) // no step while no surface is attached
                        begin(++gen)
                    }
                }
            }
            assertFalse(health.inputAllowed)
            now += 100
        }
        assertEquals(listOf(1_000L to Action.RESTART_CODEC, 3_000L to Action.RESTART_CODEC, 6_000L to Action.RECONNECT),
            actions)
        assertTrue(health.manual)
        assertTrue(health.showOverlay)
        assertTrue(logs.toString(), logs.any { it.startsWith("W video_recover step=manual n=4") })

        // "Yeniden dene": restart now, then the rest of the ladder once more.
        val t1 = now
        assertEquals(Action.RESTART_CODEC, health.retry())
        begin(++gen)
        assertFalse(health.manual)
        val again = ArrayList<Pair<Long, Action>>()
        while (now - t1 <= 600_000) {
            tick()?.let { a -> again.add((now - t1) to a); if (a == Action.RESTART_CODEC) begin(++gen) }
            now += 100
        }
        assertEquals(listOf(2_000L to Action.RESTART_CODEC, 5_000L to Action.RECONNECT), again)
        assertTrue(health.manual)
    }

    @Test fun aFaultAfterBriefHealthContinuesTheLadderInsteadOfStartingOver() {
        healthy(1)
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        var gen = 1
        var automatic = 0
        // A decoder that comes back for a moment after every restart and then dies again.
        repeat(50) {
            var a: Action? = null
            while (a == null) { now += 100; a = tick(); if (health.manual) break }
            if (a == null) return@repeat
            automatic++
            if (a == Action.RESTART_CODEC) begin(++gen) else { health.onEvent(Detached(gen)); begin(++gen) }
            now += 200
            health.onEvent(FirstOutput(gen))
            assertTrue(health.inputAllowed)
            now += 1_000
            health.onEvent(Fault(gen, FaultCause.GIVE_UP))
        }
        assertEquals("restart, restart, reconnect; never more", 3, automatic)
        assertTrue(health.manual)
    }

    @Test fun anEpisodeEndsAfterTenSecondsHealthyAndTheNextFaultStartsAFreshLadder() {
        healthy(1)
        health.onEvent(Fault(1, FaultCause.GIVE_UP))
        now += 1_000
        assertEquals(Action.RESTART_CODEC, tick())
        begin(2)
        assertTrue(health.showOverlay) // recovering
        health.onEvent(FirstOutput(2))
        assertFalse(health.showOverlay)
        now += 9_999
        tick()
        assertTrue(health.recovering)
        now += 1
        tick()
        assertFalse(health.recovering)
        health.onEvent(Fault(2, FaultCause.NO_OUTPUT))
        now += 999
        assertNull(tick())
        now += 1
        assertEquals(Action.RESTART_CODEC, tick())
    }

    @Test fun retryWithoutASurfaceDoesNothing() {
        assertNull(health.retry())
        healthy(1)
        health.onEvent(Detached(1))
        assertNull(health.retry())
    }

    // ---- DecodeProgress ----

    @Test fun decodeProgressCountsPerGenerationAndReportsTheFirstOutputOnce() {
        val p = DecodeProgress()
        p.begin(3)
        p.onInput(2, 10) // other generation
        assertEquals(0, p.snapshot().pending)
        p.onInput(3, 10); p.onInput(3, 20); p.onInput(3, 30)
        assertEquals(3, p.snapshot().pending)
        assertEquals(10, p.snapshot().oldestPendingMs)
        assertFalse(p.onOutput(2))
        assertTrue(p.onOutput(3))
        assertFalse(p.onOutput(3))
        assertEquals(0, p.snapshot().pending)
        p.onInput(3, 40)
        assertEquals(40, p.snapshot().oldestPendingMs)
        p.begin(4)
        assertEquals(4, p.snapshot().gen)
        assertEquals(0, p.snapshot().pending)
        assertTrue(p.onOutput(4))
    }

    // ---- debug fault injection ----

    @Test fun decoderFaultModesParse() {
        assertEquals(DecoderFault.Mode.SILENT, DecoderFault.parseMode("silent"))
        assertEquals(DecoderFault.Mode.CREATE, DecoderFault.parseMode("create"))
        assertEquals(DecoderFault.Mode.CONFIGURE, DecoderFault.parseMode("configure"))
        assertEquals(DecoderFault.Mode.DEQUEUE, DecoderFault.parseMode("dequeue"))
        assertNull(DecoderFault.parseMode(null))
        assertNull(DecoderFault.parseMode("SILENT"))
        assertNull(DecoderFault.parseMode("other"))
    }

    @Test fun dequeueFaultHitsTheRunningGenerationOnceItWasHealthyLongEnough() {
        val inner = FakeDecoderFactory()
        val lines = ArrayList<String>()
        val f = DecoderFault(DecoderFault.Mode.DEQUEUE, 10, inner) { lines.add(it) }
        val running = f.create("video/hevc")
        val info = DecoderCodec.OutputInfo()
        assertEquals(DecoderCodec.INFO_TRY_AGAIN_LATER, running.dequeueOutputBuffer(info, 0))
        f.onHealthy(true, 9_999, 1)
        assertFalse(f.fired)
        f.onHealthy(true, 10_000, 1)
        assertTrue(f.active)
        assertEquals(listOf("mode=dequeue armed_s=10"), lines)
        assertThrows { running.dequeueOutputBuffer(info, 0) }
        assertThrows { f.create("video/hevc").dequeueOutputBuffer(info, 0) } // a decode_error restart, same generation
        f.onGeneration(2) // the recovery's new generation runs clean
        assertFalse(f.active)
        assertEquals(DecoderCodec.INFO_TRY_AGAIN_LATER, f.create("video/hevc").dequeueOutputBuffer(info, 0))
        f.onHealthy(true, 60_000, 2)
        f.onGeneration(3)
        assertFalse(f.active)
        assertEquals("fires once per launch", 1, lines.size)
    }

    @Test fun aZeroDelayFaultWaitsForHealthyVideoEvenWhenTheConnectionIsSlow() {
        for (mode in DecoderFault.Mode.values()) {
            val lines = ArrayList<String>()
            val h = VideoHealth({ now })
            val f = DecoderFault(mode, 0, FakeDecoderFactory()) { lines.add(it) }
            // Connecting for 5 s: no surface, no generation (IDLE, generation -1); the ticker runs every 500 ms.
            repeat(10) { now += 500; f.onTick(h) }
            assertEquals(State.IDLE, h.state)
            assertFalse("$mode fired before any video", f.fired)
            // The first generation starts but takes 3 s to its first output (STARTING).
            h.onEvent(Generation(1)); f.onGeneration(1); h.onEvent(Running(1))
            repeat(6) { now += 500; f.onTick(h) }
            assertFalse("$mode fired while STARTING", f.fired)
            // FAULT is not HEALTHY either.
            h.onEvent(Fault(1, FaultCause.GIVE_UP))
            f.onTick(h)
            assertFalse("$mode fired in FAULT", f.fired)
            h.onEvent(Generation(2)); f.onGeneration(2); h.onEvent(Running(2))
            h.onEvent(FirstOutput(2))
            f.onTick(h) // HEALTHY for 0 ms >= 0 s: fires now, against the healthy generation
            assertEquals(listOf("mode=${mode.logName} armed_s=0"), lines)
            if (mode == DecoderFault.Mode.DEQUEUE || mode == DecoderFault.Mode.SILENT) {
                assertTrue("$mode must hit the running, healthy generation", f.active)
            } else {
                assertFalse(f.active) // the healthy generation keeps running ...
                f.onGeneration(3)
                assertTrue("$mode must hit the next generation", f.active) // ... the next one fails
            }
        }
    }

    @Test fun silentFaultDrainsTheCodecWithoutReportingOutput() {
        val inner = FakeDecoderFactory().also { it.produceOutput = true }
        val f = DecoderFault(DecoderFault.Mode.SILENT, 0, inner) {}
        val c = f.create("video/hevc")
        val info = DecoderCodec.OutputInfo()
        c.queueInputBuffer(c.dequeueInputBuffer(0), 0, 10, 1, 0)
        assertEquals(0, c.dequeueOutputBuffer(info, 0)) // not fired yet: output passes
        f.onHealthy(true, 0, 1)
        c.queueInputBuffer(c.dequeueInputBuffer(0), 0, 10, 2, 0)
        assertEquals(DecoderCodec.INFO_TRY_AGAIN_LATER, c.dequeueOutputBuffer(info, 0))
        assertEquals(2, inner.outputsDequeued) // the real codec did decode it ...
        assertEquals(1, inner.count("releaseOutput#1")) // ... and the buffer went back unrendered
    }

    @Test fun createAndConfigureFaultsHitTheNextGenerationOnly() {
        for (mode in listOf(DecoderFault.Mode.CREATE, DecoderFault.Mode.CONFIGURE)) {
            val inner = FakeDecoderFactory()
            val lines = ArrayList<String>()
            val f = DecoderFault(mode, 5, inner) { lines.add(it) }
            f.onHealthy(true, 5_000, 4)
            assertEquals(listOf("mode=${mode.logName} armed_s=5"), lines)
            assertFalse(f.active) // the running generation keeps going
            f.create("video/hevc").configure(DecoderFormat("video/hevc", 16, 16), Any())
            f.onGeneration(5) // e.g. a mode change
            assertTrue(f.active)
            repeat(4) { // every codec of that generation fails (-> give-up)
                assertThrows { f.create("video/hevc").configure(DecoderFormat("video/hevc", 16, 16), Any()) }
            }
            f.onGeneration(6)
            assertFalse(f.active)
            f.create("video/hevc").configure(DecoderFormat("video/hevc", 16, 16), Any())
            assertEquals(1, lines.size)
        }
    }

    private fun assertThrows(block: () -> Unit) {
        try { block() } catch (_: Exception) { return }
        fail("expected an exception")
    }

    // ---- the real renderer threads (T-158 fake codec) ----

    private val config = StreamConfig(1, StreamConfig.CODEC_HEVC, 2800, 1840, 1400, 920, 60, 50000, 1, 13, 1, 1)
    private val factory = FakeDecoderFactory().also { it.produceOutput = true }
    private val env = TestDecoderEnv()
    private val kfRequests = CopyOnWriteArrayList<Int>()
    private val events = EventLog()
    private var codecFactory: DecoderCodec.Factory = factory
    private val renderer by lazy {
        VideoRenderer(config, onKeyframeRequest = { kfRequests.add(it) }, bufferFrames = 0, codecFactory = codecFactory,
            env = env, onHealthEvent = { events.add(it) })
    }
    private var delivered = 0

    /** Delivers the renderer's events to [health] in order, as the activity's UI-thread posts would. */
    private fun deliver() {
        val all = events.all()
        while (delivered < all.size) health.onEvent(all[delivered++])
    }

    @After fun tearDown() {
        factory.stopGate?.countDown(); factory.releaseGate?.countDown(); factory.dequeueOutputGate?.countDown()
        renderer.detachSurface()
    }

    @Test fun rendererGenerationsAndFirstOutputDriveTheGate() {
        renderer.attachTarget(Any())
        assertEquals(Generation(1), events.all().first()) // synchronous, before the decoder thread runs
        deliver()
        assertEquals(State.STARTING, health.state)
        sendKeyframe()
        assertTrue(events.await { FirstOutput(1) in it })
        deliver()
        assertEquals(State.HEALTHY, health.state)
        assertTrue(Running(1) in events.all())

        // Migration / mode change: reconfigure() is a new generation; input closes until its first output.
        renderer.reconfigure(config)
        deliver()
        assertEquals(State.STARTING, health.state)
        assertFalse(health.inputAllowed)
        assertTrue(env.awaitLines("codec_start", 2))
        sendKeyframe()
        assertTrue(events.await { FirstOutput(2) in it })
        deliver()
        assertTrue(health.inputAllowed)

        // Automatic reconnect: detach + attach is a new generation too.
        renderer.detachSurface()
        deliver()
        assertEquals(State.IDLE, health.state)
        renderer.attachTarget(Any())
        deliver()
        assertEquals(State.STARTING, health.state)
        assertTrue(env.awaitLines("codec_start", 3))
        sendKeyframe()
        assertTrue(events.await { FirstOutput(3) in it })
        deliver()
        assertTrue(health.inputAllowed)
    }

    @Test fun aCodecRestartAfterDecodeErrorIsNotANewGeneration() {
        renderer.attachTarget(Any())
        sendKeyframe()
        assertTrue(events.await { FirstOutput(1) in it })
        deliver()
        assertTrue(health.inputAllowed)

        factory.dequeueOutputFailures = 1
        assertTrue(env.awaitLines("decode_error"))
        assertTrue(env.awaitLines("codec_start", 2))
        sendKeyframe()
        val outs = factory.outputsDequeued
        assertTrue(factory.await { outputsDequeued > outs })
        deliver()
        assertEquals(State.HEALTHY, health.state)
        assertTrue(health.inputAllowed)
        assertEquals(1, events.all().count { it is Generation })
        assertEquals(1, events.all().count { it is FirstOutput })
        assertTrue(events.all().none { it is Exited || it is Fault })
    }

    @Test fun giveUpReportsAFaultAndTheDeadGenerationIsNotFed() {
        factory.failCreates = 4
        renderer.attachTarget(Any())
        assertTrue(events.await { Fault(1, FaultCause.GIVE_UP) in it })
        assertTrue(events.await { Exited(1) in it })
        deliver()
        assertEquals(State.FAULT, health.state)
        assertFalse(renderer.feeding)
        assertTrue(renderer.attached)

        val received = renderer.stats.snapshot().received
        val requests = kfRequests.size
        for (seq in 1L..200L) renderer.onFrame(frame(seq, if (seq == 1L) VideoFrame.KEYFRAME else 0))
        assertEquals("frames reached the queue of a dead decoder", received, renderer.stats.snapshot().received)
        assertEquals(requests, kfRequests.size)
        assertFalse(renderer.takeKeyframeRetry())

        // Recovery step: a new generation on the same surface is fed again.
        renderer.restartCodec()
        deliver()
        assertEquals(State.STARTING, health.state)
        assertTrue(renderer.feeding)
        assertTrue(env.awaitLines("codec_start"))
        sendKeyframe()
        assertTrue(events.await { FirstOutput(2) in it })
        deliver()
        assertTrue(health.inputAllowed)
    }

    @Test fun stopFeedingDropsFramesUntilTheNextGeneration() {
        renderer.attachTarget(Any())
        assertTrue(env.awaitLines("codec_start"))
        renderer.stopFeeding()
        val received = renderer.stats.snapshot().received
        renderer.onFrame(frame(1, VideoFrame.KEYFRAME))
        assertEquals(received, renderer.stats.snapshot().received)
        renderer.restartCodec()
        renderer.onFrame(frame(2, VideoFrame.KEYFRAME))
        assertEquals(received + 1, renderer.stats.snapshot().received)
    }

    @Test fun injectedDequeueFaultEndsInGiveUpAndTheNextGenerationRecovers() {
        val fault = DecoderFault(DecoderFault.Mode.DEQUEUE, 0, factory) {}
        codecFactory = fault
        renderer.attachTarget(Any())
        sendKeyframe()
        assertTrue(events.await { FirstOutput(1) in it })
        fault.onHealthy(true, 0, 1)
        assertTrue(events.await { Fault(1, FaultCause.GIVE_UP) in it })
        assertEquals(4, env.lines("decode_error").size)
        deliver()
        assertEquals(State.FAULT, health.state)

        renderer.restartCodec() // the ladder's first step
        fault.onGeneration(2) // the activity forwards each Generation to the fault
        deliver()
        assertTrue(env.awaitLines("codec_start", 5))
        sendKeyframe()
        assertTrue(events.await { FirstOutput(2) in it })
        deliver()
        assertEquals(State.HEALTHY, health.state)
    }

    private var seq = 0L

    private fun sendKeyframe() {
        renderer.onFrame(frame(++seq, VideoFrame.CODEC_CONFIG))
        renderer.onFrame(frame(++seq, VideoFrame.KEYFRAME))
    }

    private fun frame(seq: Long, flags: Int) = VideoFrame(seq, seq * 1000, flags, 0, 1, 3, Bytes(byteArrayOf(0, 0, 1)))

    /** Thread-safe event log with a monitor wait (no sleeps). */
    private class EventLog {
        private val lock = Object()
        private val list = ArrayList<HealthEvent>()

        fun add(e: HealthEvent) = synchronized(lock) { list.add(e); lock.notifyAll() }
        fun all(): List<HealthEvent> = synchronized(lock) { ArrayList(list) }

        fun await(timeoutMs: Long = 5_000, condition: (List<HealthEvent>) -> Boolean): Boolean {
            val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
            synchronized(lock) {
                while (!condition(list)) {
                    val left = TimeUnit.NANOSECONDS.toMillis(deadline - System.nanoTime())
                    if (left <= 0) return false
                    lock.wait(left)
                }
                return true
            }
        }
    }
}
