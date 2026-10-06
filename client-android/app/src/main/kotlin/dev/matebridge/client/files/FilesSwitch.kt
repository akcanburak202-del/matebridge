package dev.matebridge.client.files

import dev.matebridge.client.session.Transport
import java.util.Random

/**
 * What the "Tablet dosyaları" status line shows (T-135; NO_USB_SESSION: T-153, now "no trusted session yet", either
 * transport; WIFI_STANDBY and WIFI_READY: T-269, decision 0035).
 */
enum class FilesStatus { DISABLED, NO_PERMISSION, PAUSED, NO_USB_SESSION, WIFI_STANDBY, STARTING, READY, WIFI_READY, FAILED }

/** Pure decisions around the file server (T-135, decision 0015). */
object FilesSwitch {
    /**
     * The server runs only when the user switched it on, "all files access" is granted, the app is in the foreground
     * (the session ends in the background anyway) and the current session is trusted ([FilesSessionGate]: accepted,
     * locally trusted, an authenticated STREAM_CONFIG applied on this connection) and either runs over USB (T-153) or
     * over Wi-Fi after the Mac's `FILES_NET(OPEN)` ([netOpen], decision 0035: there is no separate Wi-Fi setting, the
     * click on the Mac is the consent). [transport] is the current connection's, null without one.
     */
    fun shouldRun(
        enabled: Boolean, permission: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?,
        netOpen: Boolean = false,
    ) = enabled && permission && foreground && sessionTrusted &&
        (transport == Transport.USB || (transport == Transport.WIFI && netOpen))

    /**
     * FILES_INFO STANDBY (PROTOCOL.md 0x09, decision 0035): everything [shouldRun] needs holds on a Wi-Fi session, the
     * server is off and waits for the Mac. Never on USB.
     */
    fun standbyEligible(enabled: Boolean, permission: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?) =
        enabled && permission && foreground && sessionTrusted && transport == Transport.WIFI

    /** Status while the server is not running: the first missing condition of [shouldRun], in that order. */
    fun idleStatus(
        enabled: Boolean, permission: Boolean, foreground: Boolean,
        sessionTrusted: Boolean = false, transport: Transport? = null,
    ): FilesStatus = when {
        !enabled -> FilesStatus.DISABLED
        !permission -> FilesStatus.NO_PERMISSION
        !foreground -> FilesStatus.PAUSED
        standbyEligible(enabled, permission, foreground, sessionTrusted, transport) -> FilesStatus.WIFI_STANDBY
        else -> FilesStatus.NO_USB_SESSION
    }

    /** `reason=` of the `server state=off` log line when [shouldRun] is false. */
    fun stopReason(
        enabled: Boolean, permission: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport? = null,
    ): String = when {
        !enabled -> "disabled"
        !permission -> "no_permission"
        !foreground -> "background"
        !sessionTrusted -> "no_session"
        transport == Transport.WIFI -> "net_closed"
        else -> "wifi"
    }

    fun statusText(s: FilesStatus): String = when (s) {
        FilesStatus.DISABLED -> "Durum: kapalı"
        FilesStatus.NO_PERMISSION -> "Durum: \"Tüm dosyalara erişim\" izni yok. Anahtarı kapatıp açın ve izni verin."
        FilesStatus.PAUSED -> "Durum: uygulama ön planda değil"
        FilesStatus.NO_USB_SESSION -> "Durum: Mac'e bağlanınca açılır (USB'de hemen, Wi-Fi'da Mac'ten açılınca)"
        FilesStatus.WIFI_STANDBY -> "Durum: Mac'ten açılmayı bekliyor (Wi-Fi)"
        FilesStatus.STARTING -> "Durum: başlatılıyor…"
        FilesStatus.READY -> "Durum: hazır. Mac'te menü çubuğu → \"Tablet dosyalarını aç\" (USB ile)"
        FilesStatus.WIFI_READY -> "Durum: Mac'e açık (Wi-Fi, MateBridge/Wi-Fi)"
        FilesStatus.FAILED -> "Durum: sunucu başlatılamadı"
    }

    /** A fresh HTTP password: 128 random bits as 32 lowercase hex characters (PROTOCOL.md 0x09). */
    fun newToken(random: Random): String {
        val b = ByteArray(16).also { random.nextBytes(it) }
        return b.joinToString("") { "%02x".format(it.toInt() and 0xFF) }
    }
}
