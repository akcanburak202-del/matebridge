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

    @Test fun nonMmapOrUnknownAaudioIsRejectedInEveryPreferenceAndTrackIsNext() {
        // T-100 review M1: a legacy AAudio stream ignores the write timeout, so a stop could hang.
        for (pref in listOf(AudioOutPref.AUTO, AudioOutPref.AAUDIO)) {
            for (mmap in listOf(0, -1)) {
                for ((choice, exclusive) in listOf(excl to true, excl to false, shared to false)) {
                    val p = SinkPolicy(pref, true)
                    assertEquals("$pref $mmap $choice", SinkPolicy.Verdict.REJECT, p.onOpened(choice, exclusive, mmap))
                    assertEquals(track, p.next())
                    p.reset()
                    assertEquals(excl, p.next())
                }
            }
        }
    }

    @Test fun disableAaudioIsImmediateAndSticky() {
        val p = SinkPolicy(AudioOutPref.AAUDIO, true)
        p.disableAaudio()
        assertTrue(p.aaudioDisabled)
        p.reset()
        assertEquals(track, p.next())
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

    @Test fun sharedIsOnProbationInAuto() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        p.onOpenFailed(excl)
        assertEquals(SinkPolicy.Verdict.PROBATION, p.onOpened(shared, exclusive = false, mmap = 1))
    }

    @Test fun aaudioPrefSkipsTheProbation() {
        val p = SinkPolicy(AudioOutPref.AAUDIO, true)
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(excl, exclusive = false, mmap = 1))
        assertEquals(SinkPolicy.Verdict.ACCEPT, p.onOpened(shared, exclusive = false, mmap = 1))
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

    // ---- T-101: the panel's "Ses çıkışı" ----

    @Test fun setPrefSwitchesBetweenLowLatencyAndCompatible() {
        val p = SinkPolicy(AudioOutPref.AUTO, true)
        assertEquals(excl, p.next())
        assertTrue(p.setPref(AudioOutPref.TRACK))
        assertEquals(AudioOutPref.TRACK, p.pref)
        assertEquals(track, p.next())
        assertFalse(p.setPref(AudioOutPref.TRACK)) // no change, no rebuild
        assertTrue(p.setPref(AudioOutPref.AUTO))
        assertEquals(excl, p.next())
    }

    @Test fun startingAsTrackCanSwitchToAaudioLater() {
        // AudioPlayout passes aaudioAvailable = true for TRACK (the library is not loaded then): AAUDIO must be possible later.
        val p = SinkPolicy(AudioOutPref.TRACK, aaudioAvailable = true)
        assertEquals(track, p.next())
        p.setPref(AudioOutPref.AUTO)
        assertEquals(excl, p.next())
    }

    @Test fun setPrefRestartsTheChainAndForgetsFailuresButNotABrokenLibrary() {
        val p = SinkPolicy(AudioOutPref.AUTO, true, maxFailures = 2)
        p.onOpenFailed(excl)
        p.onAaudioFailure(0)
        assertTrue(p.onAaudioFailure(1))
        assertEquals(track, p.next())
        p.setPref(AudioOutPref.TRACK)
        p.setPref(AudioOutPref.AUTO) // the user asked for low latency again
        assertFalse(p.aaudioDisabled)
        assertEquals(excl, p.next())

        p.disableAaudio()
        p.setPref(AudioOutPref.TRACK)
        p.setPref(AudioOutPref.AUTO)
        assertTrue(p.aaudioDisabled)
        assertEquals(track, p.next())
    }

    @Test fun launchExtraOverridesTheStoredSettingWithoutReplacingIt() {
        val none = AudioOutPref.resolve(null, AudioOutPref.TRACK)
        assertEquals(AudioOutPref.TRACK, none.pref)
        assertEquals("setting", none.source)
        assertFalse(none.unknownExtra)

        val extra = AudioOutPref.resolve("aaudio", AudioOutPref.TRACK)
        assertEquals(AudioOutPref.AAUDIO, extra.pref)
        assertEquals("extra", extra.source)

        assertEquals(AudioOutPref.TRACK, AudioOutPref.resolve("track", AudioOutPref.AUTO).pref)
        assertEquals(AudioOutPref.AUTO, AudioOutPref.resolve("auto", AudioOutPref.TRACK).pref)

        val bad = AudioOutPref.resolve("oboe", AudioOutPref.TRACK)
        assertEquals(AudioOutPref.TRACK, bad.pref) // unknown extra: the stored setting
        assertEquals("setting", bad.source)
        assertTrue(bad.unknownExtra)
    }

    @Test fun prefIdsRoundTrip() {
        for (p in AudioOutPref.values()) assertEquals(p, AudioOutPref.parse(p.id))
    }
}
