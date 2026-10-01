package dev.matebridge.client.audio

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SinkPolicyTest {
    private val excl = OutChoice.AAUDIO_EXCLUSIVE
    private val shared = OutChoice.AAUDIO_SHARED
    private val track = OutChoice.TRACK

    @Test fun parsesTheSwitch() {
        assertEquals(AudioOutPref.AUTO, AudioOutPref.parse(null))
        assertEquals(AudioOutPref.AUTO, AudioOutPref.parse(""))
        assertEquals(AudioOutPref.AUTO, AudioOutPref.parse("auto"))
        assertEquals(AudioOutPref.AAUDIO, AudioOutPref.parse("aaudio"))
        assertEquals(AudioOutPref.AAUDIO, AudioOutPref.parse(" AAudio "))
        assertEquals(AudioOutPref.TRACK, AudioOutPref.parse("track"))
        assertNull(AudioOutPref.parse("oboe"))
    }

    @Test fun autoPrefersExclusiveMmap() {
        val p = SinkPolicy(AudioOutPref.AUTO, aaudioAvailable = true)
        assertEquals(excl, p.next())
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(excl, exclusive = true, mmap = 1))
        assertEquals(excl, p.next())
    }

    @Test fun unknownMmapStateWithExclusiveSharingIsAccepted() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(excl, exclusive = true, mmap = -1))
    }

    @Test fun exclusiveOpenFailureFallsToSharedThenTrack() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        p.onOpenFailed(excl)
        assertEquals(shared, p.next())
        p.onOpenFailed(shared)
        assertEquals(track, p.next())
    }

    @Test fun exclusiveGrantedAsSharedIsOnProbationAndRejectionGoesToTrack() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        assertEquals(SinkPolicy.Verdict.PROBATION, p.onOpened(excl, exclusive = false, mmap = 1))
        assertEquals(shared, p.next())
        p.onProbationFailed()
        assertEquals(track, p.next())
    }

    @Test fun exclusiveWithoutMmapIsOnProbation() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        assertEquals(SinkPolicy.Verdict.PROBATION, p.onOpened(excl, exclusive = true, mmap = 0))
    }

    @Test fun sharedIsOnProbationInAuto() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        p.onOpenFailed(excl)
        assertEquals(SinkPolicy.Verdict.PROBATION, p.onOpened(shared, exclusive = false, mmap = 0))
    }

    @Test fun aaudioPrefSkipsTheProbation() {
        val p = SinkPolicy(AudioOutPref.AAUDIO, true)
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(excl, exclusive = false, mmap = 0))
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(shared, exclusive = false, mmap = 0))
    }

    @Test fun aaudioPrefStillFallsBackToTrackWhenAaudioCannotOpen() {
        val p = SinkPolicy(AudioOutPref.AAUDIO, true)
        p.onOpenFailed(excl)
        p.onOpenFailed(shared)
        assertEquals(track, p.next())
    }

    @Test fun trackPrefAndMissingLibraryUseTrackOnly() {
        assertEquals(track, SinkPolicy(AudioOutPref.TRACK, true).next())
        val p = SinkPolicy(AudioOutPref.AUTO, aaudioAvailable = false)
        assertTrue(p.aaudioDisabled)
        p.reset()
        assertEquals(track, p.next())
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(track, false, -1))
    }

    @Test fun resetRetriesTheChain() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        p.onOpenFailed(excl)
        p.onProbationFailed()
        assertEquals(track, p.next())
        p.reset()
        assertEquals(excl, p.next())
    }

    @Test fun repeatedAaudioFailuresSwitchToTrackForGood() {
        val p = SinkPolicy(AudioOutPref.AUTO, true, maxFailures = 3, windowMs = 10_000)
        assertFalse(p.onAaudioFailure(0))
        assertFalse(p.onAaudioFailure(4_000))
        assertTrue(p.onAaudioFailure(8_000))
        assertEquals(track, p.next())
        p.reset() // new stream, new device: AAudio stays off
        assertEquals(track, p.next())
        assertFalse(p.onAaudioFailure(9_000)) // reported once
    }

    @Test fun spreadOutFailuresDoNotDisableAaudio() {
        val p = SinkPolicy(AudioOutPref.AUTO, true, maxFailures = 3, windowMs = 10_000)
        assertFalse(p.onAaudioFailure(0))
        assertFalse(p.onAaudioFailure(6_000))
        assertFalse(p.onAaudioFailure(12_000)) // the first one left the window
        assertFalse(p.onAaudioFailure(30_000))
        assertEquals(excl, p.next())
    }

    @Test fun aaudioPrefAlsoFallsBackAfterRepeatedFailures() {
        val p = SinkPolicy(AudioOutPref.AAUDIO, true, maxFailures = 2)
        p.onAaudioFailure(0)
        assertTrue(p.onAaudioFailure(1))
        assertEquals(track, p.next())
    }
}
