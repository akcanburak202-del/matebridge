package dev.matebridge.client.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HzPinTest {
    /** Stand-in for an API 34 `LayoutParams`: the AOSP refresh fields plus one vendor-looking field. */
    @Suppress("unused")
    class Api34Params {
        @JvmField var preferredRefreshRate = 0f
        @JvmField var preferredMinDisplayRefreshRate = 0f
        @JvmField var preferredMaxDisplayRefreshRate = 0f
        @JvmField var preferredDisplayModeId = 0
        @JvmField var hwFrameRateHint = 0
        @JvmField var title = ""
    }

    /** Stand-in for the tablet's API 31 `LayoutParams`: no min/max fields. */
    @Suppress("unused")
    class Api31Params {
        @JvmField var preferredRefreshRate = 0f
        @JvmField var preferredDisplayModeId = 0
    }

    @Suppress("unused")
    class OddParams {
        @JvmField var preferredMinDisplayRefreshRate = 0 // wrong type
        @JvmField val preferredMaxDisplayRefreshRate = 0f // final

        companion object {
            @JvmField var staticRefreshRate = 0f
        }
    }

    @Test fun variantParsing() {
        assertEquals(HzPinVariant.OFF, HzPinVariant.parse(null))
        assertEquals(HzPinVariant.OFF, HzPinVariant.parse("off"))
        assertEquals(HzPinVariant.LP, HzPinVariant.parse(" Lp "))
        assertEquals(HzPinVariant.ALL, HzPinVariant.parse("ALL"))
        assertEquals(HzPinVariant.OFF, HzPinVariant.parse("120"))
        assertEquals(HzPinVariant.OFF, HzPinVariant.parse(""))
        assertEquals(setOf("off", "lp", "all"), HzPinVariant.IDS)
    }

    @Test fun offAndOtherModesPlanNothing() {
        for (v in HzPinVariant.entries) {
            assertEquals(emptyList<HzPinHint>(), HzPin.plan(v, isGame = false, streamFps = 60))
            assertEquals(emptyList<HzPinHint>(), HzPin.plan(v, isGame = true, streamFps = 120))
            assertEquals(emptyList<HzPinHint>(), HzPin.plan(v, isGame = true, streamFps = 0))
        }
        assertEquals(emptyList<HzPinHint>(), HzPin.plan(HzPinVariant.OFF, isGame = true, streamFps = 60))
        assertFalse(HzPin.reapplies(HzPin.plan(HzPinVariant.OFF, true, 60)))
    }

    @Test fun variantsMapToHints() {
        assertEquals(listOf(HzPinHint.LP_RATE, HzPinHint.LP_MINMAX), HzPin.plan(HzPinVariant.LP, true, 60))
        assertFalse(HzPin.reapplies(HzPin.plan(HzPinVariant.LP, true, 60)))
        val all = HzPin.plan(HzPinVariant.ALL, true, 60)
        assertEquals(listOf(HzPinHint.LP_RATE, HzPinHint.LP_MINMAX, HzPinHint.HW_LP, HzPinHint.REAPPLY), all)
        assertTrue(HzPin.reapplies(all))
    }

    @Test fun floatFieldIsWrittenOrReportedMissing() {
        val p = Api34Params()
        assertEquals(HzPinResult.OK, HzPin.setFloatField(p, HzPin.FIELD_PREFERRED_REFRESH_RATE, 60f))
        assertEquals(60f, p.preferredRefreshRate)
        assertEquals(HzPinResult.OK, HzPin.setMinMax(p, 60f))
        assertEquals(60f, p.preferredMinDisplayRefreshRate)
        assertEquals(60f, p.preferredMaxDisplayRefreshRate)
        assertEquals(HzPinResult.OK, HzPin.setMinMax(p, 0f))
        assertEquals(0f, p.preferredMinDisplayRefreshRate)

        val old = Api31Params()
        assertEquals(HzPinResult.MISSING, HzPin.setMinMax(old, 60f))
        assertEquals(HzPinResult.OK, HzPin.setFloatField(old, HzPin.FIELD_PREFERRED_REFRESH_RATE, 60f))
    }

    @Test fun wrongTypeFinalOrStaticFieldIsAnError() {
        val p = OddParams()
        assertEquals(HzPinResult.ERROR, HzPin.setFloatField(p, HzPin.FIELD_MIN_RATE, 60f))
        assertEquals(HzPinResult.ERROR, HzPin.setFloatField(p, HzPin.FIELD_MAX_RATE, 60f))
        assertEquals(0f, p.preferredMaxDisplayRefreshRate)
        assertEquals(HzPinResult.ERROR, HzPin.setMinMax(p, 60f))
    }

    @Test fun worseResultWins() {
        assertEquals(HzPinResult.MISSING, HzPin.worse(HzPinResult.OK, HzPinResult.MISSING))
        assertEquals(HzPinResult.ERROR, HzPin.worse(HzPinResult.ERROR, HzPinResult.MISSING))
        assertEquals(HzPinResult.OK, HzPin.worse(HzPinResult.OK, HzPinResult.OK))
    }

    @Test fun vendorDiscoveryListsNonAospRefreshFieldsOnly() {
        assertEquals(listOf("hwFrameRateHint"), HzPin.vendorFields(Api34Params::class.java))
        assertEquals(emptyList<String>(), HzPin.vendorFields(Api31Params::class.java))
        assertEquals(emptyList<String>(), HzPin.vendorFields(OddParams::class.java)) // the static field is skipped
        assertEquals(HzPinResult.MISSING, HzPin.vendorResult(emptyList(), hwClassPresent = false))
        assertEquals(HzPinResult.OK, HzPin.vendorResult(emptyList(), hwClassPresent = true))
        assertEquals(HzPinResult.OK, HzPin.vendorResult(listOf("hwFrameRateHint"), hwClassPresent = false))
    }

    @Test fun logFields() {
        assertEquals("variant=off state=off applied=-", HzPin.logFields(HzPinVariant.OFF, false, emptyList()))
        assertEquals(
            "variant=lp state=on applied=lp_rate:ok,lp_minmax:missing",
            HzPin.logFields(HzPinVariant.LP, true, listOf(HzPinHint.LP_RATE to HzPinResult.OK, HzPinHint.LP_MINMAX to HzPinResult.MISSING)),
        )
        assertEquals("a,b_2", HzPin.fieldList(listOf("a", "b_2", "x y", "1bad")))
        assertEquals("-", HzPin.fieldList(emptyList()))
    }

    @Test fun switchCounterCountsChangesPerWindow() {
        val c = HzSwitchCounter()
        c.observe(60) // first report of a run is not a switch
        assertEquals(0, c.take())
        c.observe(120)
        c.observe(60)
        c.observe(60)
        c.observe(0) // unknown ignored
        assertEquals(2, c.take())
        assertEquals(0, c.take())
        c.observe(120) // the last rate survives the window
        assertEquals(1, c.take())
        c.restart()
        c.observe(60)
        assertEquals(0, c.take())
    }
}
