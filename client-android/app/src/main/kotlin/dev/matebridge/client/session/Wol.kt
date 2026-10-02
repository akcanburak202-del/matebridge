package dev.matebridge.client.session

/**
 * T-129 Wake-on-LAN, pure parts. The host publishes its interface hardware addresses in the Bonjour TXT key `wol`
 * (PROTOCOL.md section 3.1); the tablet stores them with the last seen host IPv4 and sends magic packets when the Mac
 * cannot be reached. MAC and IP addresses are never logged.
 */
object WolTxt {
    const val KEY = "wol"
    const val MAX_ADDRESSES = 4

    /**
     * Parses a TXT `wol` value: comma-separated `aa:bb:cc:dd:ee:ff`. Hex case is tolerated (normalised to lower case);
     * malformed, all-zero and multicast/broadcast addresses and duplicates are skipped; at most [MAX_ADDRESSES] are kept.
     * Returns an empty list when nothing usable is in it (also for null).
     */
    fun parse(raw: String?): List<String> {
        if (raw == null) return emptyList()
        val out = ArrayList<String>(MAX_ADDRESSES)
        for (part in raw.split(',')) {
            if (out.size >= MAX_ADDRESSES) break
            val mac = normalize(part.trim()) ?: continue
            if (mac !in out) out += mac
        }
        return out
    }

    /** Six bytes of a normalised (or tolerated) MAC string, or null when it is not one. */
    fun bytes(mac: String): ByteArray? {
        val groups = mac.split(':')
        if (groups.size != 6) return null
        val b = ByteArray(6)
        for ((i, g) in groups.withIndex()) {
            if (g.length != 2 || !g.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) return null
            b[i] = g.toInt(16).toByte()
        }
        return b
    }

    private fun normalize(s: String): String? {
        val b = bytes(s) ?: return null
        if (b.all { it == 0.toByte() }) return null
        if (b[0].toInt() and 0x01 != 0) return null // group bit: multicast or broadcast, never a NIC
        return b.joinToString(":") { "%02x".format(it.toInt() and 0xFF) }
    }
}

object WolPacket {
    const val PORT = 9
    const val SIZE = 6 + 16 * 6

    /** Magic packet: 6 × 0xFF then the 6-byte MAC 16 times (102 bytes). */
    fun magic(mac: ByteArray): ByteArray {
        require(mac.size == 6) { "MAC must be 6 bytes" }
        val p = ByteArray(SIZE)
        for (i in 0 until 6) p[i] = 0xFF.toByte()
        for (r in 0 until 16) System.arraycopy(mac, 0, p, 6 + r * 6, 6)
        return p
    }
}

object WolTargets {
    val LIMITED_BROADCAST = byteArrayOf(-1, -1, -1, -1)

    /** Dotted-quad IPv4 literal to 4 bytes; anything else (names, IPv6, out-of-range parts) is null. */
    fun parseIpv4(s: String?): ByteArray? {
        if (s == null) return null
        val parts = s.split('.')
        if (parts.size != 4) return null
        val b = ByteArray(4)
        for ((i, p) in parts.withIndex()) {
            if (p.isEmpty() || p.length > 3 || !p.all { it in '0'..'9' }) return null
            val v = p.toInt()
            if (v > 255) return null
            b[i] = v.toByte()
        }
        return b
    }

    /** Directed broadcast of [addr]/[prefix]; null for a prefix outside 0..30 (/31 and /32 have no broadcast) or a bad address. */
    fun subnetBroadcast(addr: ByteArray, prefix: Int): ByteArray? {
        if (addr.size != 4 || prefix !in 0..30) return null
        val a = ((addr[0].toInt() and 0xFF) shl 24) or ((addr[1].toInt() and 0xFF) shl 16) or
            ((addr[2].toInt() and 0xFF) shl 8) or (addr[3].toInt() and 0xFF)
        val mask = if (prefix == 0) 0 else (-1 shl (32 - prefix))
        val bc = a or mask.inv()
        return byteArrayOf((bc ushr 24).toByte(), (bc ushr 16).toByte(), (bc ushr 8).toByte(), bc.toByte())
    }

    /**
     * Send targets in order: 255.255.255.255, each subnet broadcast of the Wi-Fi link, then the last seen host IPv4
     * (unicast). Duplicates are dropped; an unparsable [lastHost] is skipped.
     */
    fun build(subnetBroadcasts: List<ByteArray>, lastHost: String?): List<ByteArray> {
        val out = ArrayList<ByteArray>()
        fun add(b: ByteArray) { if (out.none { it.contentEquals(b) }) out += b }
        add(LIMITED_BROADCAST)
        subnetBroadcasts.forEach { add(it) }
        parseIpv4(lastHost)?.let { add(it) }
        return out
    }
}

/** An IPv4 subnet (network address + prefix length); used to recognise the home Wi-Fi without logging addresses. */
data class Ipv4Subnet(val network: Int, val prefix: Int) {
    fun contains(addr: ByteArray): Boolean = addr.size == 4 && (toInt(addr) and mask(prefix)) == network

    override fun toString(): String =
        "${network ushr 24}.${(network ushr 16) and 0xFF}.${(network ushr 8) and 0xFF}.${network and 0xFF}/$prefix"

    companion object {
        /** The subnet [addr]/[prefix] lies in (host bits cleared); null for a bad address or a prefix outside 1..32. */
        fun of(addr: ByteArray, prefix: Int): Ipv4Subnet? {
            if (addr.size != 4 || prefix !in 1..32) return null
            return Ipv4Subnet(toInt(addr) and mask(prefix), prefix)
        }

        /** "a.b.c.d/p" as written by [toString]; host bits are cleared. */
        fun parse(s: String?): Ipv4Subnet? {
            if (s == null) return null
            val i = s.indexOf('/')
            if (i <= 0) return null
            val addr = WolTargets.parseIpv4(s.substring(0, i)) ?: return null
            val prefix = s.substring(i + 1).takeIf { p -> p.isNotEmpty() && p.length <= 2 && p.all { it in '0'..'9' } }?.toInt() ?: return null
            return of(addr, prefix)
        }

        private fun mask(prefix: Int) = if (prefix == 0) 0 else (-1 shl (32 - prefix))

        private fun toInt(b: ByteArray) = ((b[0].toInt() and 0xFF) shl 24) or ((b[1].toInt() and 0xFF) shl 16) or
            ((b[2].toInt() and 0xFF) shl 8) or (b[3].toInt() and 0xFF)
    }
}

/** Automatic wake only on the home network (the Wi-Fi subnet the host was seen on). Manual wake is not restricted. */
object HomeNetwork {
    const val SKIP_OTHER_NETWORK = "other_network"
    const val SKIP_NO_WIFI = "no_wifi"
    const val SKIP_HOME_UNKNOWN = "home_unknown"

    /** The current Wi-Fi subnet to remember with the host: the one containing [hostIpv4], else the first one. */
    fun pick(current: List<Ipv4Subnet>, hostIpv4: String?): Ipv4Subnet? {
        val host = WolTargets.parseIpv4(hostIpv4)
        return current.firstOrNull { host != null && it.contains(host) } ?: current.firstOrNull()
    }

    /** Null when an automatic episode may start, else the skip reason for the log. */
    fun skipReason(stored: Ipv4Subnet?, current: List<Ipv4Subnet>): String? = when {
        stored == null -> SKIP_HOME_UNKNOWN
        current.isEmpty() -> SKIP_NO_WIFI
        stored in current -> null
        else -> SKIP_OTHER_NETWORK
    }
}

/**
 * Persisted wake data (SharedPreferences through [KeyValueStore]): the host's MAC addresses, its IPv4 and the tablet's
 * Wi-Fi subnet at that time (the home network). Written from the NSD callback thread, read on the main thread.
 */
class WolStore(private val store: KeyValueStore) {
    private var macs: List<String> = WolTxt.parse(store.getString(KEY_MACS))
    private var host: String? = store.getString(KEY_HOST)?.takeIf { WolTargets.parseIpv4(it) != null }
    private var subnet: Ipv4Subnet? = Ipv4Subnet.parse(store.getString(KEY_SUBNET))

    @Synchronized fun macs(): List<String> = macs

    @Synchronized fun host(): String? = host

    @Synchronized fun subnet(): Ipv4Subnet? = subnet

    @Synchronized fun hasMacs(): Boolean = macs.isNotEmpty()

    /**
     * A resolved service. Only a [txtWol] with at least one valid address stores anything: the MAC list, [hostIpv4] and
     * the Wi-Fi [wifiSubnet] it was seen on (a null subnet keeps the stored one). A missing or unusable value keeps
     * everything stored (older host, transient state). Returns true when the MAC list or the home subnet changed.
     */
    @Synchronized
    fun onResolved(hostIpv4: String, txtWol: String?, wifiSubnet: Ipv4Subnet?): Boolean {
        val parsed = WolTxt.parse(txtWol)
        if (parsed.isEmpty()) return false
        if (WolTargets.parseIpv4(hostIpv4) != null && hostIpv4 != host) {
            host = hostIpv4
            store.putString(KEY_HOST, hostIpv4)
        }
        var changed = false
        if (wifiSubnet != null && wifiSubnet != subnet) {
            subnet = wifiSubnet
            store.putString(KEY_SUBNET, wifiSubnet.toString())
            changed = true
        }
        if (parsed != macs) {
            macs = parsed
            store.putString(KEY_MACS, parsed.joinToString(","))
            changed = true
        }
        return changed
    }

    private companion object {
        const val KEY_MACS = "wol_macs"
        const val KEY_HOST = "wol_host"
        const val KEY_SUBNET = "wol_subnet"
    }
}

/**
 * When to send magic packets (T-129). Pure and clock-injected; main thread only.
 *
 * While in the foreground and not reached for [GRACE_MS], with stored addresses, an episode starts: one send every
 * [INTERVAL_MS] for at most [EPISODE_MS]. Reaching the host stops it at once; the background stops it (nothing is ever
 * sent in the background). After a timeout the next automatic episode waits [COOLDOWN_MS]; a manual request ignores
 * the wait (and extends a running episode). Coming back to the foreground or reaching the host clears the wait.
 * Automatic episodes start only on the home network ([HomeNetwork]); off it a [Step.Skip] is reported once per reason
 * and the check repeats every [SKIP_RECHECK_MS]. Manual requests are never restricted.
 */
class WakePlanner {
    sealed interface Step {
        data class Start(val reason: String) : Step
        data object Send : Step
        data class Stop(val reason: String) : Step
        /** An automatic episode was due but not started (e.g. not on the home network); for the log only. */
        data class Skip(val reason: String) : Step
    }

    var active = false
        private set
    private var episodeStartMs = 0L
    private var lastSendMs = 0L
    private var notReachedSinceMs = -1L
    private var cooldownUntilMs = Long.MIN_VALUE
    private var wasForeground = false
    private var skipUntilMs = Long.MIN_VALUE
    private var lastSkip: String? = null

    /**
     * One step of the automatic policy. [userOff]: the user pressed "Bağlantıyı kes" (no automatic reconnect, so no
     * automatic wake either). [reached]: the host answered (see [reached] for a session state). [skipReason] is asked
     * only when an automatic episode is due: null allows it, anything else is the reason it is skipped. [hostAsleep]
     * (T-133): the host said BYE(HOST_SLEEP); nothing automatic is sent until the user acts or the app comes back.
     */
    fun update(
        nowMs: Long, foreground: Boolean, userOff: Boolean, reached: Boolean, hasWol: Boolean,
        hostAsleep: Boolean = false,
        skipReason: () -> String? = { null },
    ): List<Step> {
        if (!foreground || userOff || hostAsleep) {
            wasForeground = foreground
            notReachedSinceMs = -1
            return stop(
                when {
                    !foreground -> REASON_BACKGROUND
                    userOff -> REASON_USER
                    else -> REASON_HOST_SLEEP
                },
            )
        }
        if (!wasForeground) {
            wasForeground = true
            cooldownUntilMs = Long.MIN_VALUE // a fresh start (screen on, app opened) may wake again at once
            clearSkip()
        }
        if (reached) {
            notReachedSinceMs = -1
            cooldownUntilMs = Long.MIN_VALUE
            clearSkip()
            return stop(REASON_CONNECTED)
        }
        if (notReachedSinceMs < 0) notReachedSinceMs = nowMs
        if (active) {
            if (nowMs - episodeStartMs >= EPISODE_MS) {
                cooldownUntilMs = nowMs + COOLDOWN_MS
                return stop(REASON_TIMEOUT)
            }
            if (nowMs - lastSendMs >= INTERVAL_MS) {
                lastSendMs = nowMs
                return listOf(Step.Send)
            }
            return emptyList()
        }
        if (!hasWol || nowMs - notReachedSinceMs < GRACE_MS || nowMs < cooldownUntilMs || nowMs < skipUntilMs) return emptyList()
        val skip = skipReason()
        if (skip != null) {
            skipUntilMs = nowMs + SKIP_RECHECK_MS
            if (skip == lastSkip) return emptyList()
            lastSkip = skip
            return listOf(Step.Skip(skip))
        }
        clearSkip()
        return start(nowMs, REASON_AUTO)
    }

    /** "Mac'i uyandır": starts at once regardless of the wait; a running episode is extended and sends now. */
    fun manual(nowMs: Long, reached: Boolean, hasWol: Boolean): List<Step> {
        if (!hasWol || reached) return emptyList()
        cooldownUntilMs = Long.MIN_VALUE
        if (active) {
            episodeStartMs = nowMs
            lastSendMs = nowMs
            return listOf(Step.Send)
        }
        return start(nowMs, REASON_MANUAL)
    }

    private fun start(nowMs: Long, reason: String): List<Step> {
        active = true
        episodeStartMs = nowMs
        lastSendMs = nowMs
        return listOf(Step.Start(reason), Step.Send)
    }

    private fun clearSkip() {
        skipUntilMs = Long.MIN_VALUE
        lastSkip = null
    }

    private fun stop(reason: String): List<Step> {
        if (!active) return emptyList()
        active = false
        return listOf(Step.Stop(reason))
    }

    companion object {
        const val GRACE_MS = 2_000L
        const val INTERVAL_MS = 1_000L
        const val EPISODE_MS = 20_000L
        const val COOLDOWN_MS = 30_000L
        const val SKIP_RECHECK_MS = 5_000L

        const val REASON_AUTO = "not_found"
        const val REASON_MANUAL = "manual"
        const val REASON_CONNECTED = "connected"
        const val REASON_TIMEOUT = "timeout"
        const val REASON_BACKGROUND = "background"
        const val REASON_USER = "user"
        const val REASON_HOST_SLEEP = "host_sleep"

        /**
         * The host answered, so it is awake: a session (or pairing) is up, it gave a terminal answer (REJECTED, ...), or
         * the connection ended with an answer from it (BUSY, BYE, a protocol error: [SessionUi.Disconnected] with a
         * retry). A connect that failed or a session that was lost (what a Mac going to sleep looks like) is not reached.
         */
        fun reached(ui: SessionUi): Boolean = when (ui) {
            is SessionUi.Connected, is SessionUi.AwaitingApproval, is SessionUi.Failed -> true
            is SessionUi.Disconnected -> ui.cause in ANSWERED_CAUSES
            SessionUi.Idle, SessionUi.Searching, is SessionUi.Connecting -> false
        }

        private val ANSWERED_CAUSES = setOf(
            SessionUi.Cause.BUSY, SessionUi.Cause.HOST_CLOSED, SessionUi.Cause.PROTOCOL_ERROR,
            SessionUi.Cause.REJECTED, SessionUi.Cause.VERSION_MISMATCH, SessionUi.Cause.KEY_MISSING,
            SessionUi.Cause.KEY_STORE_FAILED,
        )
    }
}
