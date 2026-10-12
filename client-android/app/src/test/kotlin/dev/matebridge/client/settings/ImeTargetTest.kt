package dev.matebridge.client.settings

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ImeTargetTest {
    @Test fun connectPanelIsImeTarget() = assertTrue(ImeTarget.windowIsImeTarget(streamVisible = false, settingsPanelOpen = false))
    @Test fun streamIsNotImeTarget() = assertFalse(ImeTarget.windowIsImeTarget(streamVisible = true, settingsPanelOpen = false))
    @Test fun openSettingsPanelIsNotImeTarget() = assertFalse(ImeTarget.windowIsImeTarget(streamVisible = true, settingsPanelOpen = true))
}
