package dev.matebridge.client.session

/** Host address plus control port. Pure value type, no name resolution. */
data class Endpoint(val host: String, val port: Int) {
    override fun toString() = "$host:$port"

    companion object {
        /** Parses "host:port" (IPv4 or DNS name). Returns null on anything malformed. */
        fun parse(text: String): Endpoint? {
            val t = text.trim()
            val i = t.lastIndexOf(':')
            if (i <= 0 || i == t.length - 1) return null
            val host = t.substring(0, i)
            if (host.any { it.isWhitespace() || it == ':' }) return null
            val port = t.substring(i + 1).toIntOrNull() ?: return null
            if (port !in 1..65535) return null
            return Endpoint(host, port)
        }
    }
}
