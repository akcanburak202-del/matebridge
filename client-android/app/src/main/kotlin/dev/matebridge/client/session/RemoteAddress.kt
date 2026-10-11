package dev.matebridge.client.session

/**
 * Decision 0038 section 1: the remote address field. IPv4 (a Tailscale 100.x address) or a DNS name (MagicDNS), an
 * optional `:port` (default [DEFAULT_PORT]); a trailing dot of the name is dropped; IPv6 is not supported (like [Endpoint]).
 * Pure; never logs the address.
 */
object RemoteAddress {
    const val DEFAULT_PORT = 47001
    private const val MAX_HOST = 253
    private const val MAX_LABEL = 63

    /** Returns null for anything malformed or empty. */
    fun parse(text: String): Endpoint? {
        val t = text.trim()
        if (t.isEmpty() || t.any { it.isWhitespace() }) return null
        val colon = t.indexOf(':')
        if (colon != t.lastIndexOf(':')) return null // more than one colon: IPv6 (or garbage)
        val hostPart = if (colon >= 0) t.substring(0, colon) else t
        val port = if (colon >= 0) {
            val p = t.substring(colon + 1)
            if (p.isEmpty() || p.length > 5 || p.any { it !in '0'..'9' }) return null
            p.toInt().takeIf { it in 1..65535 } ?: return null
        } else DEFAULT_PORT
        val host = hostPart.removeSuffix(".")
        if (host.isEmpty() || host.length > MAX_HOST) return null
        // A dotted-number name is an IPv4 literal and must be a valid one (never a DNS name like "999.1.1.1").
        if (host.all { it in '0'..'9' || it == '.' }) {
            if (!validIpv4(host)) return null
        } else if (!validName(host)) return null
        return Endpoint(host.lowercase(java.util.Locale.ROOT), port)
    }

    /** The form shown in the field: no port when it is the default. */
    fun display(ep: Endpoint): String = if (ep.port == DEFAULT_PORT) ep.host else ep.toString()

    private fun validIpv4(s: String): Boolean {
        val parts = s.split('.')
        if (parts.size != 4) return false
        return parts.all { p -> p.isNotEmpty() && p.length <= 3 && p.toInt() in 0..255 }
    }

    private fun validName(s: String): Boolean {
        for (label in s.split('.')) {
            if (label.isEmpty() || label.length > MAX_LABEL) return false
            if (label.first() == '-' || label.last() == '-') return false
            if (label.any { !(it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-') }) return false
        }
        return true
    }
}
