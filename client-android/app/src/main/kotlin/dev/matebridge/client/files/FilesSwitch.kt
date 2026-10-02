package dev.matebridge.client.files

import java.util.Random

/** What the "Tablet dosyaları" status line shows (T-135). */
enum class FilesStatus { DISABLED, NO_PERMISSION, PAUSED, STARTING, READY, FAILED }

/** Pure decisions around the file server (T-135, decision 0015). */
object FilesSwitch {
    /**
     * The server runs only when the user switched it on, "all files access" is granted and the app is in the
     * foreground (the session ends in the background anyway, so the Mac could not reach it).
     */
    fun shouldRun(enabled: Boolean, permission: Boolean, foreground: Boolean) = enabled && permission && foreground

    /** Status while the server is not running. */
    fun idleStatus(enabled: Boolean, permission: Boolean): FilesStatus = when {
        !enabled -> FilesStatus.DISABLED
        !permission -> FilesStatus.NO_PERMISSION
        else -> FilesStatus.PAUSED
    }

    fun statusText(s: FilesStatus): String = when (s) {
        FilesStatus.DISABLED -> "Durum: kapalı"
        FilesStatus.NO_PERMISSION -> "Durum: \"Tüm dosyalara erişim\" izni yok. Anahtarı kapatıp açın ve izni verin."
        FilesStatus.PAUSED -> "Durum: uygulama ön planda değil"
        FilesStatus.STARTING -> "Durum: başlatılıyor…"
        FilesStatus.READY -> "Durum: hazır. Mac'te menü çubuğu → \"Tablet dosyalarını aç\" (yalnızca USB ile)"
        FilesStatus.FAILED -> "Durum: sunucu başlatılamadı"
    }

    /** A fresh HTTP password: 128 random bits as 32 lowercase hex characters (PROTOCOL.md 0x09). */
    fun newToken(random: Random): String {
        val b = ByteArray(16).also { random.nextBytes(it) }
        return b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }
}
