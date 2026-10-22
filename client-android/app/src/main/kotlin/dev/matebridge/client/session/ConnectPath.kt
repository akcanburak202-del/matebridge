package dev.matebridge.client.session

/** Decision 0042: the connect screen's path choice. */
enum class ConnectPath(val id: String) {
    /** USB (`adb reverse`) and Bonjour discovery, full quality. Never a typed or Tailscale address. */
    LOCAL("local"),
    /** The stored Tailscale address (0038 remote session with "Veri tasarrufu", else a normal session). */
    TAILSCALE("tailscale"),
    ;

    companion object {
        fun parse(s: String?): ConnectPath = entries.firstOrNull { it.id == s } ?: LOCAL
    }
}

/** The remembered choice: [saver] only means something on [ConnectPath.TAILSCALE]. */
data class ConnectChoice(val path: ConnectPath, val saver: Boolean) {
    companion object {
        val DEFAULT = ConnectChoice(ConnectPath.LOCAL, saver = false)
    }
}

/** What "Bağlan" does for a [ConnectChoice] (decision 0042 sections 2 to 5). */
sealed interface ConnectPlan {
    /** The usual local way (the transport mode decides USB / Bonjour); never an address of the user's. */
    data object Local : ConnectPlan

    /** Tailscale: [saver] = the 0038 remote session; otherwise a normal session without WoL or discovery. */
    data class Tailscale(val endpoint: Endpoint, val saver: Boolean) : ConnectPlan

    /** Tailscale chosen, no (valid) address stored: ask for it first. */
    data object NeedAddress : ConnectPlan
}

object ConnectPlanner {
    fun plan(choice: ConnectChoice, tailscale: Endpoint?): ConnectPlan = when (choice.path) {
        ConnectPath.LOCAL -> ConnectPlan.Local
        ConnectPath.TAILSCALE ->
            if (tailscale == null) ConnectPlan.NeedAddress else ConnectPlan.Tailscale(tailscale, choice.saver)
    }

    /** Whether the Wake-on-LAN button belongs to the choice (local only). */
    fun allowsWake(choice: ConnectChoice) = choice.path == ConnectPath.LOCAL

    /** The "Veri tasarrufu" switch is shown only on Tailscale. */
    fun showsSaver(choice: ConnectChoice) = choice.path == ConnectPath.TAILSCALE
}

/**
 * Decision 0042 section 6: nothing connects by itself at start. [engaged] is set by "Bağlan" and cleared by "Durdur" /
 * "Bağlantıyı kes"; it lives in memory only, so a fresh process always waits. Going to the background and back keeps it
 * (the same way reconnects, as before). Main thread only.
 */
class ConnectGate {
    var engaged = false
        private set

    fun onConnectPressed() { engaged = true }

    fun onStopped() { engaged = false }

    /** At `onStart`: true = start waiting for "Bağlan" (no connect, discovery, probe or Wake-on-LAN). */
    fun waitingOnStart(): Boolean = !engaged
}

/** The label of the one big button: "Durdur" only while a connection attempt or retry is running. */
object ConnectButton {
    fun isStop(engaged: Boolean, ui: SessionUi): Boolean = engaged && when (ui) {
        SessionUi.Searching, is SessionUi.Connecting, is SessionUi.Disconnected -> true
        else -> false
    }
}

/** Decision 0042 section 2: which addresses may become `lastWifiEndpoint` (the local AUTO fallback target). */
object WifiMemory {
    fun mayRemember(origin: ConnectOrigin, ep: Endpoint, pinnedSession: Boolean): Boolean =
        !pinnedSession && origin != ConnectOrigin.REMOTE && origin != ConnectOrigin.TAILSCALE &&
            origin != ConnectOrigin.TYPED_ADDRESS && !isTailscaleAddress(ep.host)

    /** 100.64.0.0/10 (CGNAT, Tailscale) or a MagicDNS `.ts.net` name. */
    fun isTailscaleAddress(host: String): Boolean {
        val h = host.lowercase(java.util.Locale.ROOT).removeSuffix(".")
        if (h.endsWith(".ts.net")) return true
        val p = h.split('.')
        if (p.size != 4) return false
        val a = p[0].toIntOrNull() ?: return false
        val b = p[1].toIntOrNull() ?: return false
        return a == 100 && b in 64..127
    }
}

/** Decision 0042 section 7: the old manual address is moved to the Tailscale address once, or dropped. */
object TailscaleMigration {
    /** [newTailscale] = the address to store (null = leave as is); the old manual key is always removed. */
    data class Result(val newTailscale: Endpoint?)

    fun migrate(oldManual: Endpoint?, tailscale: Endpoint?): Result =
        if (oldManual != null && tailscale == null && WifiMemory.isTailscaleAddress(oldManual.host)) {
            Result(oldManual)
        } else {
            Result(null)
        }
}
