package dev.matebridge.client.session

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo

/**
 * Finds the host via mDNS `_matebridge._tcp` (PROTOCOL.md section 3.1). NsdManager resolves one
 * service at a time, so found services are queued. Callbacks arrive on NsdManager's own thread.
 * Thin Android wrapper, verified on the device only.
 */
@Suppress("DEPRECATION")
class MacDiscovery(context: Context, private val onFound: (Endpoint) -> Unit) {
    private val nsd = context.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null

    @Synchronized
    fun start() {
        if (listener != null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { clear() }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceLost(info: NsdServiceInfo) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(this@MacDiscovery) { pending.addLast(info) }
                resolveNext()
            }
        }
        listener = l
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
    }

    @Synchronized
    fun stop() {
        val l = listener ?: return
        listener = null
        pending.clear()
        try { nsd.stopServiceDiscovery(l) } catch (_: IllegalArgumentException) {}
    }

    @Synchronized
    private fun clear() { listener = null }

    private fun resolveNext() {
        val next = synchronized(this) {
            if (resolving) return
            val n = pending.removeFirstOrNull() ?: return
            resolving = true
            n
        }
        nsd.resolveService(next, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) = done()
            override fun onServiceResolved(info: NsdServiceInfo) {
                val addr = info.host
                if (addr != null && info.port > 0) {
                    // Prefer a literal IPv4 address; link-local IPv6 would need a scope id.
                    val host = addr.hostAddress
                    if (host != null && !host.contains(':')) onFound(Endpoint(host, info.port))
                }
                done()
            }

            private fun done() {
                synchronized(this@MacDiscovery) { resolving = false }
                resolveNext()
            }
        })
    }

    private companion object {
        const val SERVICE_TYPE = "_matebridge._tcp."
    }
}
