package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesInfo
import dev.matebridge.client.protocol.FilesNet
import dev.matebridge.client.session.Transport

/**
 * T-153: whether the current session may serve files, i.e. the `sessionTrusted` and `transport` inputs of
 * [FilesSwitch.shouldRun]. Trusted means: the UI shows the session as Connected **and** an authenticated STREAM_CONFIG
 * was applied on the current connection generation. Connected alone is not enough: a PAIRED connection reports it at the
 * plaintext HELLO_ACK, before any sealed record proved the host's key, while STREAM_CONFIG is sealed and is applied only
 * on a locally trusted session (T-150). A new connection generation (reconnect or migration) or any non-Connected state
 * drops the trust until that connection's own STREAM_CONFIG is applied.
 *
 * The transport is the connection's own (reported with its generation), not the endpoint the UI targets.
 *
 * T-269 (decision 0035): the gate also remembers the Mac's `FILES_NET(OPEN)` of the current connection generation
 * ([netOpen]); a new generation or any non-Connected state forgets it (the host closes its file connections with the
 * session). A OPEN with another listener port is a change as well.
 *
 * Every call returns whether ([trusted], transport, net) changed, so the caller re-syncs the server only then. Main thread.
 */
class FilesSessionGate {
    private var connGen = -1
    private var connTransport: Transport? = null
    private var configGen = -1
    private var connected = false
    private var net: FilesNet? = null
    private var netRequest = 0

    val trusted: Boolean get() = connected && connGen >= 0 && configGen == connGen

    /** The newest control connection generation the UI has seen (-1 before the first). */
    val generation: Int get() = connGen

    /** The current connection's transport; null before the first connection. */
    val transport: Transport? get() = connTransport

    /** The Mac asked to open the files over Wi-Fi on this connection and has not closed them. */
    val netOpen: Boolean get() = net != null

    /** The machine's id of the open request in [net] (0 = none): what a server started now serves and publishes. */
    val netRequestId: Int get() = if (net != null) netRequest else 0

    /** A new control connection (also a migration's promoted candidate) became the session's. */
    fun onConnectionGen(gen: Int, transport: Transport): Boolean = changes {
        connGen = gen
        connTransport = transport
        net = null
        netRequest = 0
    }

    /** `FILES_NET` of connection [gen]: OPEN is remembered, CLOSE (or any unknown state) forgets it; another generation is ignored. */
    fun onFilesNet(gen: Int, msg: FilesNet, request: Int = 0): Boolean = changes {
        if (gen == connGen) {
            net = if (msg.isOpen) msg else null
            netRequest = if (msg.isOpen) request else 0
        }
    }

    /** An authenticated STREAM_CONFIG was applied; it belongs to the current generation (same ordered thread). */
    fun onConfigApplied(): Boolean = changes { configGen = connGen }

    /**
     * The tablet side no longer allows sharing (the setting went off or the permission is gone): the Mac has been told OFF
     * and closed its end, so its earlier open request must not start the server again when sharing is switched back on.
     * The Mac's menu sends a new one.
     */
    fun forgetNet(): Boolean = changes { net = null; netRequest = 0 }

    /** The rendered session state: Connected or anything else. */
    fun onUi(connected: Boolean): Boolean = changes {
        this.connected = connected
        if (!connected) { configGen = -1; net = null; netRequest = 0 }
    }

    private inline fun changes(f: () -> Unit): Boolean {
        val before = key()
        f()
        return key() != before
    }

    /** Null while untrusted, else the transport the trusted session runs on and the Mac's open request. */
    private fun key(): Triple<Transport?, FilesNet?, Int>? = if (trusted) Triple(connTransport, net, netRequest) else null
}

/**
 * Start/stop of the tablet-files server (T-135 rules, moved out of [FilesController] by T-153 so they are JVM-testable):
 *
 * - at most one server; every start gets a fresh token from [newToken];
 * - READY (with that token) is published only from [Events.onListening] of the live server, OFF is published under the
 *   lock **before** a stopped server is told to stop, so a READY can never overtake the OFF of a stop that raced it;
 * - callbacks of a server that was stopped on purpose are ignored (generation check);
 * - a server that ends by itself publishes OFF and reports [FilesStatus.FAILED];
 * - the last stopped server is handed to the next start ([Factory.create] `after`), which waits for its workers;
 * - T-269 (decision 0035): over Wi-Fi the server runs only after the Mac's open request (`netOpen`), as a Wi-Fi server
 *   ([Events.wifi]: its own root and profile). While a Wi-Fi session is allowed but not open, [FilesInfo.STANDBY] is
 *   published (once); a Wi-Fi server stopped by the Mac's CLOSE publishes STANDBY instead of OFF.
 *
 * [sync] and [shutdown] are main-thread calls; [Events] may arrive on the server's own threads.
 */
class FilesLifecycle<S : FilesLifecycle.Server>(
    private val factory: Factory<S>,
    private val newToken: () -> String,
    private val publish: (FilesInfo) -> Unit,
    private val onStatus: () -> Unit,
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit,
    /**
     * T-269 round 3: when set, used instead of [publish]; every FILES_INFO carries the [FilesServerScope] of the server it
     * describes (READY: that server's kind and control generation; OFF and STANDBY: [FilesServerScope.NONE]).
     */
    private val publishScoped: ((FilesInfo, FilesServerScope) -> Unit)? = null,
) {
    private fun emit(info: FilesInfo, scope: FilesServerScope) {
        val p = publishScoped
        if (p != null) p(info, scope) else publish(info)
    }

    interface Server {
        fun start()
        fun stop()
    }

    interface Events {
        /** This server is a Wi-Fi server (decision 0035): Wi-Fi root and profile, started by the Mac's open request. */
        val wifi: Boolean

        fun onListening(port: Int)
        fun onStopped(failed: Boolean)
    }

    fun interface Factory<S> {
        fun create(token: String, events: Events, after: S?): S
    }

    private val lock = Any()
    private var server: S? = null
    /** The last stopped server: the next one listens only after its workers (a running COPY/DELETE) ended. */
    private var retired: S? = null
    private var gen = 0

    /** The running server is a Wi-Fi server; and STANDBY is the last thing published (both guarded by [lock]). */
    private var serverWifi = false
    private var serverGen = -1
    private var serverRequest = 0

    /** The running server's port and token once it listens (0 / null before), to re-publish READY for a new request. */
    private var serverPort = 0
    private var serverToken: String? = null
    private var standbyShown = false

    @Volatile var status = FilesStatus.DISABLED
        private set

    /** Starts or stops the server for the inputs of [FilesSwitch.shouldRun]. Main thread. */
    fun sync(
        enabled: Boolean, permission: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?,
        netOpen: Boolean = false,
        /** The control connection generation of the session this sync belongs to (tags a server started now). */
        generation: Int = -1,
        /** The machine's id of the Mac's open request this sync acts on (0 = none); tags what is published. */
        requestId: Int = 0,
    ) {
        if (FilesSwitch.shouldRun(enabled, permission, foreground, sessionTrusted, transport, netOpen)) {
            val wifi = transport == Transport.WIFI
            // A running server of the other kind (cannot happen across a connection change, which drops trust first) goes first.
            if (synchronized(lock) { server != null && (serverWifi != wifi || serverGen != generation) }) {
                stop("mode", FilesInfo.OFF)
            }
            synchronized(lock) {
                if (server == null) startLocked(wifi, generation, requestId) else retagLocked(requestId)
            }
        } else {
            val standby = FilesSwitch.standbyEligible(enabled, permission, foreground, sessionTrusted, transport)
            stop(FilesSwitch.stopReason(enabled, permission, foreground, sessionTrusted, transport), if (standby) FilesInfo.STANDBY else FilesInfo.OFF)
            publishIdle(standby, requestId)
            setStatus(FilesSwitch.idleStatus(enabled, permission, foreground, sessionTrusted, transport))
        }
    }

    /**
     * No server runs: STANDBY goes out once when a Wi-Fi session is allowed, OFF once when that no longer holds. USB and
     * a plain OFF state publish nothing here (the machine starts at OFF), exactly as before.
     */
    private fun publishIdle(standby: Boolean, requestId: Int) {
        synchronized(lock) {
            if (standby && server == null) {
                if (!standbyShown) { standbyShown = true; emit(FilesInfo.STANDBY, idleScope(requestId)) }
            } else if (!standby && standbyShown) {
                standbyShown = false
                emit(FilesInfo.OFF, idleScope(requestId))
            }
        }
    }

    fun shutdown() = stop("destroy")

    /** OFF and STANDBY describe no server; they only name the request (or 0) they end. */
    private fun idleScope(request: Int) = FilesServerScope(false, -1, request)

    /**
     * A new open request (another port of the Mac's listener, PROTOCOL 0x0A: only the file CONNECTIONS are replaced) while
     * the same share is running: the server stays (same token, no OFF or STANDBY, the Mac must not tear down and unmount);
     * it is tagged with the new request and READY is published again for it. Before it listens, the tag is simply updated
     * (its READY then carries the new request).
     */
    private fun retagLocked(requestId: Int) {
        if (serverRequest == requestId) return
        serverRequest = requestId
        val token = serverToken
        if (serverPort != 0 && token != null) {
            emit(FilesInfo(FilesInfo.STATE_READY, serverPort, token), FilesServerScope(serverWifi, serverGen, requestId))
        }
        log(false, "server", "retag request=$requestId")
    }

    private fun startLocked(forWifi: Boolean, forGeneration: Int, forRequest: Int) {
        val myGen = ++gen
        val token = newToken()
        serverWifi = forWifi
        serverGen = forGeneration
        serverRequest = forRequest
        serverPort = 0
        serverToken = null
        standbyShown = false // READY (or OFF) supersedes STANDBY
        val s = factory.create(token, object : Events {
            override val wifi: Boolean = forWifi

            // Publishing happens under the lock (it only posts to a mailbox), so a READY can never overtake the OFF of
            // a stop() that raced with it.
            override fun onListening(port: Int) {
                synchronized(lock) {
                    if (gen != myGen) return
                    serverPort = port
                    serverToken = token
                    emit(FilesInfo(FilesInfo.STATE_READY, port, token), FilesServerScope(forWifi, forGeneration, serverRequest))
                    setStatus(if (wifi) FilesStatus.WIFI_READY else FilesStatus.READY)
                }
                log(false, "server", "state=on port=$port")
            }

            override fun onStopped(failed: Boolean) {
                synchronized(lock) {
                    if (gen != myGen) return // stopped on purpose: stop() already reported OFF
                    retired = server
                    server = null
                    emit(FilesInfo.OFF, idleScope(serverRequest))
                    setStatus(FilesStatus.FAILED)
                }
                log(true, "server", "state=off port=0 reason=${if (failed) "failed" else "ended"}")
            }
        }, retired)
        retired = null
        server = s
        setStatus(FilesStatus.STARTING)
        s.start()
    }

    /** [final] is what the host learns first: OFF, or STANDBY when the Mac closed a Wi-Fi server of a session that stays allowed. */
    private fun stop(reason: String, final: FilesInfo = FilesInfo.OFF) {
        val s = synchronized(lock) {
            val cur = server ?: return
            server = null
            retired = cur
            gen++ // late callbacks of the old server are ignored
            standbyShown = final.state == FilesInfo.STATE_STANDBY && serverWifi
            emit(if (standbyShown) FilesInfo.STANDBY else FilesInfo.OFF, idleScope(serverRequest)) // queued before the listener closes, so the host learns it as early as possible
            cur
        }
        s.stop()
        log(false, "server", "state=off port=0 reason=$reason")
    }

    private fun setStatus(s: FilesStatus) {
        synchronized(lock) {
            if (status == s) return
            status = s
        }
        onStatus()
    }
}
