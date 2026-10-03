package dev.matebridge.client.settings

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.stream.StreamMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** T-105: the one control description both panels are built from. */
class SettingsCatalogTest {
    private class FakeHost : SettingsHost {
        val calls = ArrayList<String>()
        override var transportMode = TransportMode.AUTO
        override fun selectTransport(m: TransportMode) { calls += "transport ${m.id}"; transportMode = m }
        override fun disconnect() { calls += "disconnect" }
        override val forgetHostLabel = "Bu Mac'i unut"
        override fun forgetHost() { calls += "forget" }
        override var streamMode = StreamMode.SMOOTH
        override fun selectStreamMode(m: StreamMode) { calls += "mode ${m.id}"; streamMode = m }
        override var bitrateKbps = 0L
        override fun selectBitrate(kbps: Long) { calls += "bitrate $kbps"; bitrateKbps = kbps }
        override var appliedBitrateKbps: Long? = null
        override var gameDefaultsActive = false
        override var audioAvailable = true
        val v = HashMap<String, Boolean>()
        var out = AudioOutPref.AUTO
        override val audioEnabled get() = v["audio"] ?: true
        override fun setAudioEnabled(on: Boolean) { calls += "audio $on"; v["audio"] = on }
        override val audioOut get() = out
        override fun setAudioOut(p: AudioOutPref) { calls += "audio_out ${p.id}"; out = p }
        override var touchpadSpeed = 1f
        override var mouseSpeed = 1f
        override fun stepSpeed(mouse: Boolean, factor: Float) { calls += "speed ${if (mouse) "mouse" else "pad"} $factor" }
        override val fingerTouchDisabled get() = v["finger_off"] ?: false
        override fun setFingerTouchDisabled(off: Boolean) { calls += "finger_off $off"; v["finger_off"] = off }
        override val penTrail get() = v["trail"] ?: false
        override fun setPenTrail(on: Boolean) { calls += "trail $on"; v["trail"] = on }
        override val penDot get() = v["dot"] ?: false
        override fun setPenDot(on: Boolean) { calls += "dot $on"; v["dot"] = on }
        override val filesShare get() = v["files"] ?: false
        override fun setFilesShare(on: Boolean) { calls += "files $on"; v["files"] = on }
        override var filesStatus = "Durum: kapalı"
        override val clipboardShare get() = v["clip"] ?: true
        override fun setClipboardShare(on: Boolean) { calls += "clip $on"; v["clip"] = on }
        override val statsOverlay get() = v["stats"] ?: false
        override fun setStatsOverlay(on: Boolean) { calls += "stats $on"; v["stats"] = on }
    }

    private val h = FakeHost()

    private fun item(sections: List<SettingsSection>, key: String) = sections.flatMap { it.items }.single { it.key == key }

    private fun choice(s: List<SettingsSection>, key: String) = item(s, key) as SettingItem.Choice

    @Test fun sectionsInOrder() {
        assertEquals(listOf("Bağlantı", "Görüntü", "Ses", "Girdi", "Tablet dosyaları", "Diğer"), SettingsCatalog.sections(h, inStream = true).map { it.title })
        assertEquals(listOf("Bağlantı", "Görüntü", "Ses", "Girdi", "Tablet dosyaları", "Diğer"), SettingsCatalog.sections(h, inStream = false).map { it.title })
    }

    @Test fun bothPanelsHaveTheSameControlsExceptTheStreamOnlyOnes() {
        val side = SettingsCatalog.sections(h, inStream = true).flatMap { it.items }.map { it.key }
        val connect = SettingsCatalog.sections(h, inStream = false).flatMap { it.items }.map { it.key }
        assertEquals(side - setOf("disconnect", "bitrate_applied"), connect)
        assertEquals(
            listOf(
                "transport", "disconnect", "forget_host", "stream_mode", "bitrate", "bitrate_applied", "audio", "audio_out",
                "touchpad_speed", "mouse_speed", "finger_off", "pen_trail", "pen_dot", "files", "files_status",
                "clipboard", "stats", "shortcuts", "version",
            ),
            side,
        )
    }

    @Test fun noAudioSectionWithoutAudio() {
        h.audioAvailable = false
        val s = SettingsCatalog.sections(h, inStream = true)
        assertEquals(listOf("Bağlantı", "Görüntü", "Girdi", "Tablet dosyaları", "Diğer"), s.map { it.title })
    }

    @Test fun bitrateChoices() {
        val s = SettingsCatalog.sections(h, inStream = true)
        val c = choice(s, "bitrate")
        assertEquals(listOf("Otomatik", "15 Mbps", "30 Mbps", "60 Mbps", "100 Mbps"), c.options.map { it.label })
        assertEquals("0", c.selected())
        c.select("60000")
        assertEquals(listOf("bitrate 60000"), h.calls)
        assertEquals("60000", c.selected())
        c.select("12345") // not an option: Otomatik
        assertEquals("bitrate 0", h.calls.last())
        val applied = item(s, "bitrate_applied") as SettingItem.Info
        assertEquals("Uygulanan: —", applied.text())
        h.appliedBitrateKbps = 60_000
        assertEquals("Uygulanan: 60 Mbps", applied.text())
    }

    @Test fun modeTransportAndAudioOutChoices() {
        val s = SettingsCatalog.sections(h, inStream = true)
        val mode = choice(s, "stream_mode")
        assertEquals(listOf("Netlik (60 fps)", "Akıcı (120 fps)", "Performans (120 fps)", "Oyun 120 (120 fps)", "Oyun 60 (60 fps)"), mode.options.map { it.label })
        assertEquals("smooth", mode.selected())
        mode.select("clarity")
        val tr = choice(s, "transport")
        assertEquals(listOf("auto", "usb", "wifi"), tr.options.map { it.id })
        tr.select("usb")
        val out = choice(s, "audio_out")
        assertEquals("auto", out.selected())
        out.select("track")
        assertEquals("track", out.selected())
        h.out = AudioOutPref.AAUDIO // a launch override shows as "Düşük gecikme"
        assertEquals("auto", out.selected())
        assertEquals(listOf("mode clarity", "transport usb", "audio_out track"), h.calls)
    }

    @Test fun togglesSteppersAndActions() {
        val s = SettingsCatalog.sections(h, inStream = true)
        val finger = item(s, "finger_off") as SettingItem.Toggle
        assertEquals("Parmak dokunmasını tamamen kapat: kapalı", finger.text())
        finger.set(!finger.get())
        assertEquals("Parmak dokunmasını tamamen kapat: AÇIK", finger.text())
        val stats = item(s, "stats") as SettingItem.Toggle
        assertEquals("İstatistik katmanı: kapalı", stats.text())
        stats.set(!stats.get())
        val pad = item(s, "touchpad_speed") as SettingItem.Stepper
        assertEquals("1,00", pad.value())
        pad.dec()
        (item(s, "mouse_speed") as SettingItem.Stepper).inc()
        (item(s, "disconnect") as SettingItem.Action).run()
        assertEquals(
            listOf("finger_off true", "stats true", "speed pad ${SpeedRange.STEP_DOWN}", "speed mouse ${SpeedRange.STEP_UP}", "disconnect"),
            h.calls,
        )
    }

    @Test fun shortcutListHasTheSettingsShortcut() {
        val text = (item(SettingsCatalog.sections(h, inStream = false), "shortcuts") as SettingItem.Info).text()
        assertTrue(text.contains("Ctrl+Shift+6: ayarlar paneli"))
        assertTrue(text.contains("Ctrl+Shift+7"))
    }

    @Test fun forgetHostIsInBothPanels() { // T-151: also in-stream (the controller ends the session first)
        for (inStream in listOf(false, true)) {
            val s = SettingsCatalog.sections(h, inStream)
            val a = item(s, "forget_host") as SettingItem.Action
            assertEquals("Bu Mac'i unut", a.title)
            assertTrue(a in s.single { it.title == "Bağlantı" }.items)
            a.run()
        }
        assertEquals(listOf("forget", "forget"), h.calls) // only opens the host's two-step confirmation
    }

    @Test fun connectPanelHasNoDisconnect() {
        val keys = SettingsCatalog.sections(h, inStream = false).flatMap { it.items }.map { it.key }
        assertFalse("disconnect" in keys)
        assertNull(SettingsCatalog.sections(h, inStream = false).flatMap { it.items }.firstOrNull { it.key == "bitrate_applied" })
    }

    @Test fun gameModeMarksTheLayeredSettingsOnly() { // T-109
        val s = SettingsCatalog.sections(h, inStream = true)
        val bitrate = choice(s, "bitrate")
        val out = choice(s, "audio_out")
        val trail = item(s, "pen_trail") as SettingItem.Toggle
        val dot = item(s, "pen_dot") as SettingItem.Toggle
        val mode = choice(s, "stream_mode")
        val stats = item(s, "stats") as SettingItem.Toggle
        assertEquals("Bit hızı", bitrate.titleText())
        assertEquals("Ses çıkışı", out.titleText())
        assertEquals("Kalem izi: kapalı", trail.text())
        assertEquals("Kalem noktası: kapalı", dot.text())
        h.gameDefaultsActive = true // the same items follow the host (refresh re-reads them)
        assertEquals("Bit hızı (oyun modu)", bitrate.titleText())
        assertEquals("Ses çıkışı (oyun modu)", out.titleText())
        assertEquals("Kalem izi (oyun modu): kapalı", trail.text())
        assertEquals("Kalem noktası (oyun modu): kapalı", dot.text())
        assertEquals("Görüntü modu", mode.titleText())
        assertEquals("İstatistik katmanı: kapalı", stats.text())
        h.gameDefaultsActive = false
        assertEquals("Bit hızı", bitrate.titleText())
        assertEquals("Kalem izi: kapalı", trail.text())
    }

    @Test fun filesSectionTogglesAndShowsStatus() {
        val s = SettingsCatalog.sections(h, inStream = true)
        assertEquals(listOf("files", "files_status"), s.single { it.title == "Tablet dosyaları" }.items.map { it.key })
        val t = item(s, "files") as SettingItem.Toggle
        assertEquals("Tablet dosyalarını Mac'te göster: kapalı", t.text())
        t.set(!t.get())
        assertEquals(listOf("files true"), h.calls)
        assertEquals("Tablet dosyalarını Mac'te göster: açık", t.text())
        h.filesStatus = "Durum: hazır"
        assertEquals("Durum: hazır", (item(s, "files_status") as SettingItem.Info).text())
    }
}
