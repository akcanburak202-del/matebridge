package dev.matebridge.client.settings

import dev.matebridge.client.audio.AudioOutPref
import dev.matebridge.client.files.FilesRoot
import dev.matebridge.client.idle.IdleTimeout
import dev.matebridge.client.session.SpeedRange
import dev.matebridge.client.session.TransportMode
import dev.matebridge.client.stream.GameResolution
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
        override var streamMode = StreamMode.DAILY
        override fun selectStreamMode(m: StreamMode) { calls += "mode ${m.id}"; streamMode = m }
        override var frameRate = 120
        override fun selectFrameRate(fps: Int) { calls += "fps $fps"; if (streamMode.hasFpsSetting) frameRate = fps }
        override var gameResolution = GameResolution.DEFAULT
        override fun selectGameResolution(r: GameResolution) { calls += "game_resolution ${r.id}"; gameResolution = r }
        override var bitrateKbps = 0L
        override fun selectBitrate(kbps: Long) { calls += "bitrate $kbps"; bitrateKbps = kbps }
        override var appliedBitrateKbps: Long? = null
        override var modeLayer: StreamMode? = null
        override var idleTimeout = IdleTimeout.DEFAULT
        override fun selectIdleTimeout(t: IdleTimeout) { calls += "idle ${t.id}"; idleTimeout = t }
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
        override var filesRoot = FilesRoot.DEFAULT
        override fun selectFilesRoot(r: FilesRoot) { calls += "files_root ${r.id}"; filesRoot = r }
        override val filesReadOnly get() = v["files_ro"] ?: false
        override fun setFilesReadOnly(on: Boolean) { calls += "files_ro $on"; v["files_ro"] = on }
        override var filesStatus = "Durum: kapalı"
        override val clipboardShare get() = v["clip"] ?: true
        override fun setClipboardShare(on: Boolean) { calls += "clip $on"; v["clip"] = on }
        override val statsOverlay get() = v["stats"] ?: false
        override fun setStatsOverlay(on: Boolean) { calls += "stats $on"; v["stats"] = on }
        var clock = 1_000L
        override val resetConfirm = TwoTapConfirm({ clock })
        override fun onResetArmed() { calls += "reset_armed" }
        override fun resetToDefaults() { calls += "reset" }
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
                "transport", "disconnect", "forget_host", "stream_mode", "frame_rate", "game_resolution", "bitrate", "bitrate_applied", "idle_dim", "audio", "audio_out",
                "touchpad_speed", "mouse_speed", "finger_off", "pen_trail", "pen_dot", "files", "files_root", "files_ro", "files_status",
                "clipboard", "stats", "reset_defaults", "reset_hint", "shortcuts", "version",
            ),
            side,
        )
    }

    @Test fun idleDimChoices() { // T-234, decision 0031
        val s = SettingsCatalog.sections(h, inStream = true)
        val c = choice(s, "idle_dim")
        assertEquals("Boşta karart", c.titleText())
        assertEquals(listOf("2 dk", "5 dk", "10 dk", "15 dk", "Kapalı"), c.options.map { it.label })
        assertEquals("5", c.selected())
        c.select("off")
        assertEquals(listOf("idle off"), h.calls)
        assertEquals("off", c.selected())
        c.select("bogus") // not an option: the default
        assertEquals("idle 5", h.calls.last())
        assertFalse(c.hidden())
        h.streamMode = StreamMode.GAME // visible, but marked: the counter does not run in Oyun
        assertEquals("Boşta karart (Oyun modunda kapalı)", c.titleText())
        assertFalse(c.hidden())
        h.streamMode = StreamMode.DRAWING
        assertEquals("Boşta karart", c.titleText())
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
        assertEquals(listOf("Günlük", "Çizim", "Oyun"), mode.options.map { it.label })
        assertEquals(listOf("daily", "drawing", "game"), mode.options.map { it.id })
        assertEquals("daily", mode.selected())
        mode.select("drawing")
        val tr = choice(s, "transport")
        assertEquals(listOf("auto", "usb", "wifi"), tr.options.map { it.id })
        tr.select("usb")
        val out = choice(s, "audio_out")
        assertEquals("auto", out.selected())
        out.select("track")
        assertEquals("track", out.selected())
        h.out = AudioOutPref.AAUDIO // a launch override shows as "Düşük gecikme"
        assertEquals("auto", out.selected())
        assertEquals(listOf("mode drawing", "transport usb", "audio_out track"), h.calls)
    }

    @Test fun gameResolutionChoice() {
        for (inStream in listOf(true, false)) {
            val s = SettingsCatalog.sections(h, inStream)
            val keys = s.single { it.title == "Görüntü" }.items.map { it.key }
            assertEquals(keys.indexOf("stream_mode") + 1, keys.indexOf("frame_rate")) // the rate right after the mode
            assertEquals(keys.indexOf("frame_rate") + 1, keys.indexOf("game_resolution"))
        }
        val s = SettingsCatalog.sections(h, inStream = true)
        val c = choice(s, "game_resolution")
        assertEquals("Oyun çözünürlüğü", c.titleText())
        assertEquals(listOf("1400×920", "1848×1214", "2100×1380", "2240×1472"), c.options.map { it.label })
        assertEquals(listOf("1400x920", "1848x1214", "2100x1380", "2240x1472"), c.options.map { it.id })
        assertEquals("1848x1214", c.selected())
        c.select("1400x920")
        assertEquals("1400x920", c.selected())
        c.select("bogus") // unknown: the default
        assertEquals(listOf("game_resolution 1400x920", "game_resolution 1848x1214"), h.calls)
        h.modeLayer = StreamMode.GAME // a persistent setting: never marked as part of a mode layer
        assertEquals("Oyun çözünürlüğü", c.titleText())
        h.modeLayer = StreamMode.DRAWING
        assertEquals("Oyun çözünürlüğü", c.titleText())
    }

    @Test fun frameRateChoiceIsPerModeAndFixedInDrawing() { // T-223, decision 0030 §2
        val s = SettingsCatalog.sections(h, inStream = true)
        val c = choice(s, "frame_rate")
        assertEquals(listOf("60", "120"), c.options.map { it.id })
        assertEquals(listOf("60 fps", "120 fps"), c.options.map { it.label })
        assertEquals("Kare hızı (Günlük)", c.titleText())
        assertEquals("120", c.selected())
        c.select("60")
        assertEquals("60", c.selected())
        assertFalse(c.hidden())
        h.streamMode = StreamMode.GAME // the host reports that mode's own rate
        h.frameRate = 60
        assertFalse(c.hidden())
        assertEquals("Kare hızı (Oyun)", c.titleText())
        c.select("bogus") // not a number: nothing
        assertEquals(listOf("fps 60"), h.calls)
        h.streamMode = StreamMode.DRAWING
        h.frameRate = 120
        assertTrue(c.hidden()) // decision 0030 §2: the row is not shown in Çizim
        h.streamMode = StreamMode.DAILY
        assertFalse(c.hidden()) // and it comes back
        h.streamMode = StreamMode.DRAWING
        assertEquals("Kare hızı (Çizim: hep 120)", c.titleText())
        // no other row is ever hidden
        for (it in s.flatMap { it.items }.filterIsInstance<SettingItem.Choice>().filter { it.key != "frame_rate" }) assertFalse(it.key, it.hidden())
        c.select("60") // the host ignores it in Çizim
        assertEquals("120", c.selected())
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
        val finger = item(s, "finger_off") as SettingItem.Toggle
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
        h.modeLayer = StreamMode.GAME // the same items follow the host (refresh re-reads them)
        assertEquals("Bit hızı (oyun modu)", bitrate.titleText())
        assertEquals("Ses çıkışı (oyun modu)", out.titleText())
        assertEquals("Kalem izi (oyun modu): kapalı", trail.text())
        assertEquals("Kalem noktası (oyun modu): kapalı", dot.text())
        assertEquals("Parmak dokunmasını tamamen kapat: kapalı", finger.text()) // Oyun leaves the finger switch alone
        assertEquals("Görüntü modu", mode.titleText())
        assertEquals("İstatistik katmanı: kapalı", stats.text())
        h.modeLayer = null
        assertEquals("Bit hızı", bitrate.titleText())
        assertEquals("Kalem izi: kapalı", trail.text())
    }

    @Test fun drawingModeMarksBitrateAndFingersOnly() { // T-223
        val s = SettingsCatalog.sections(h, inStream = true)
        val bitrate = choice(s, "bitrate")
        val out = choice(s, "audio_out")
        val finger = item(s, "finger_off") as SettingItem.Toggle
        val trail = item(s, "pen_trail") as SettingItem.Toggle
        val dot = item(s, "pen_dot") as SettingItem.Toggle
        h.modeLayer = StreamMode.DRAWING
        assertEquals("Bit hızı (çizim modu)", bitrate.titleText())
        assertEquals("Parmak dokunmasını tamamen kapat (çizim modu): kapalı", finger.text())
        assertEquals("Ses çıkışı", out.titleText())
        assertEquals("Kalem izi: kapalı", trail.text())
        assertEquals("Kalem noktası: kapalı", dot.text())
        h.modeLayer = null
        assertEquals("Parmak dokunmasını tamamen kapat: kapalı", finger.text())
    }

    @Test fun filesSectionTogglesAndShowsStatus() {
        val s = SettingsCatalog.sections(h, inStream = true)
        assertEquals(listOf("files", "files_root", "files_ro", "files_status"), s.single { it.title == "Tablet dosyaları" }.items.map { it.key })
        val t = item(s, "files") as SettingItem.Toggle
        assertEquals("Tablet dosyalarını Mac'te göster: kapalı", t.text())
        t.set(!t.get())
        assertEquals(listOf("files true"), h.calls)
        assertEquals("Tablet dosyalarını Mac'te göster: açık", t.text())
        h.filesStatus = "Durum: hazır"
        assertEquals("Durum: hazır", (item(s, "files_status") as SettingItem.Info).text())
    }

    @Test fun resetDefaultsIsInDigerInBothPanelsAndNeedsTwoTaps() { // T-191
        for (inStream in listOf(false, true)) {
            val s = SettingsCatalog.sections(h, inStream)
            val diger = s.single { it.title == "Diğer" }.items
            val a = item(s, "reset_defaults") as SettingItem.Action
            assertTrue(a in diger)
            assertEquals("Varsayılanlara dön", a.title)
            assertTrue(item(s, "reset_hint") in diger)
        }
    }

    @Test fun oneTapAloneResetsNothingASecondTapInTheWindowDoes() { // T-191
        val s = SettingsCatalog.sections(h, inStream = true)
        val a = item(s, "reset_defaults") as SettingItem.Action
        val hint = item(s, "reset_hint") as SettingItem.Info
        assertEquals(SettingsCatalog.RESET_IDLE, hint.text())
        a.run()
        assertEquals(listOf("reset_armed"), h.calls) // armed only
        assertEquals(SettingsCatalog.RESET_ARMED, hint.text())
        h.clock += TwoTapConfirm.WINDOW_MS - 1
        a.run()
        assertEquals(listOf("reset_armed", "reset"), h.calls)
        assertEquals(SettingsCatalog.RESET_IDLE, hint.text()) // disarmed by the reset
        a.run() // a third tap starts over
        assertEquals(listOf("reset_armed", "reset", "reset_armed"), h.calls)
    }

    @Test fun theArmedStateExpires() { // T-191
        val s = SettingsCatalog.sections(h, inStream = false)
        val a = item(s, "reset_defaults") as SettingItem.Action
        val hint = item(s, "reset_hint") as SettingItem.Info
        a.run()
        h.clock += TwoTapConfirm.WINDOW_MS // the window has passed
        assertEquals(SettingsCatalog.RESET_IDLE, hint.text())
        a.run() // only arms again
        assertEquals(listOf("reset_armed", "reset_armed"), h.calls)
        h.clock += 10
        a.run()
        assertEquals("reset", h.calls.last())
    }

    @Test fun twoTapConfirmWithAFakeClock() { // T-191
        var now = 0L
        val c = TwoTapConfirm({ now }, windowMs = 3_000)
        assertFalse(c.armed)
        assertFalse(c.tap())
        assertTrue(c.armed)
        now = 2_999
        assertTrue(c.tap())
        assertFalse(c.armed)
        assertFalse(c.tap()) // re-armed at 2_999
        now = 5_999 // exactly the window later: expired
        assertFalse(c.armed)
        assertFalse(c.tap()) // re-armed at 5_999
        c.cancel()
        assertFalse(c.armed)
        assertFalse(c.tap())
        now = 5_998 // a clock that went backwards never confirms
        assertFalse(c.armed)
        assertFalse(c.tap())
    }

    @Test fun filesFolderChoiceAndReadOnly() { // T-190, decision 0028
        val s = SettingsCatalog.sections(h, inStream = false)
        val root = choice(s, "files_root")
        assertEquals("Paylaşılan klasör", root.title)
        assertEquals(listOf("matebridge", "download", "all"), root.options.map { it.id })
        assertEquals(listOf("MateBridge", "Download", "Tüm depolama"), root.options.map { it.label })
        assertEquals("matebridge", root.selected()) // the default
        root.select("all")
        assertEquals("all", root.selected())
        root.select("bogus") // not an option: the narrow default, never the whole storage
        assertEquals("matebridge", root.selected())
        val ro = item(s, "files_ro") as SettingItem.Toggle
        assertEquals("Salt okunur: kapalı", ro.text())
        ro.set(!ro.get())
        assertEquals("Salt okunur: açık", ro.text())
        assertEquals(listOf("files_root all", "files_root matebridge", "files_ro true"), h.calls)
    }
}
