package dev.matebridge.client

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BuildInfoTest {
    private fun keys(fields: String) = fields.split(' ').map { it.substringBefore('=') }

    @Test fun logFieldsHaveExactlyTheFieldsInOrder() {
        val f = BuildInfo("0.1", "abc1234", "2026-10-03T12:34Z").logFields(31, "MRD-W00 4.3.0.130(C00E130R1P2)")
        assertEquals(listOf("version", "sha", "built", "sdk", "os_build"), keys(f))
        assertEquals("version=0.1 sha=abc1234 built=2026-10-03T12:34Z sdk=31 os_build=MRD-W00_4.3.0.130(C00E130R1P2)", f)
    }

    @Test fun emptyOrMissingShaBecomesUnknown() {
        assertTrue(BuildInfo("0.1", "", "t").logFields(31, "x").contains(" sha=unknown "))
        assertTrue(BuildInfo("0.1", null, "t").logFields(31, "x").contains(" sha=unknown "))
        assertTrue(BuildInfo("0.1", "  ", "t").logFields(31, "x").contains(" sha=unknown "))
    }

    @Test fun missingValuesKeepEveryFieldOneToken() {
        val f = BuildInfo(null, null, null).logFields(29, null)
        assertEquals("version=unknown sha=unknown built=unknown sdk=29 os_build=unknown", f)
        assertEquals(5, f.split(' ').size)
    }

    @Test fun dirtyShaIsKept() {
        assertTrue(BuildInfo("0.1", "abc1234-dirty", "t").logFields(31, "x").contains(" sha=abc1234-dirty "))
    }

    @Test fun settingsTextShowsTheSameSha() {
        val b = BuildInfo("0.1", "abc1234", "2026-10-03T12:34Z")
        assertEquals("Sürüm: 0.1 (abc1234, 2026-10-03T12:34Z)", b.settingsText())
        assertEquals("Sürüm: 0.1 (unknown, unknown)", BuildInfo("0.1", "", null).settingsText())
    }

    @Test fun currentComesFromBuildConfig() {
        val c = BuildInfo.current
        assertEquals(BuildConfig.VERSION_NAME, c.versionName)
        assertFalse(c.sha.isEmpty())
        assertFalse(c.sha.contains(' '))
    }

    @Test fun appStartIsClaimedOncePerProcess() {
        val first = BuildInfo.claimAppStart()
        assertFalse(BuildInfo.claimAppStart())
        assertFalse(BuildInfo.claimAppStart())
        assertTrue(first)
    }
}
