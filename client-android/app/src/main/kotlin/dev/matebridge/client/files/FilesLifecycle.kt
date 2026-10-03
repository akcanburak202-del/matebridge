package dev.matebridge.client.files

import dev.matebridge.client.protocol.FilesInfo
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
 * Every call returns whether ([trusted], transport) changed, so the caller re-syncs the server only then. Main thread.
 */
class FilesSessionGate {
    private var connGen = -1
    private var connTransport: Transport? = null
    private var configGen = -1
    private var connected = false

    val trusted: Boolean get() = connected && connGen >= 0 && configGen == connGen

    /** The current connection's transport; null before the first connection. */
    val transport: Transport? get() = connTransport

    /** A new control connection (also a migration's promoted candidate) became the session's. */
    fun onConnectionGen(gen: Int, transport: Transport): Boolean = changes {
        connGen = gen
        connTransport = transport
    }

    /** An authenticated STREAM_CONFIG was applied; it belongs to the current generation (same ordered thread). */
    fun onConfigApplied(): Boolean = changes { configGen = connGen }

    /** The rendered session state: Connected or anything else. */
    fun onUi(connected: Boolean): Boolean = changes {
        this.connected = connected
        if (!connected) configGen = -1
    }

    private inline fun changes(f: () -> Unit): Boolean {
        val before = key()
        f()
        return key() != before
    }

    /** Null while untrusted, else the transport the trusted session runs on. */
    private fun key(): Transport? = if (trusted) connTransport else null
}

/**
 * Start/stop of the tablet-files server (T-135 rules, moved out of [FilesController] by T-153 so they are JVM-testable):
 *
 * - at most one server; every start gets a fresh token from [newToken];
 * - READY (with that token) is published only from [Events.onListening] of the live server, OFF is published under the
 *   lock **before** a stopped server is told to stop, so a READY can never overtake the OFF of a stop that raced it;
 * - callbacks of a server that was stopped on purpose are ignored (generation check);
 * - a server that ends by itself publishes OFF and reports [FilesStatus.FAILED];
 * - the last stopped server is handed to the next start ([Factory.create] `after`), which waits for its workers.
 *
 * [sync] and [shutdown] are main-thread calls; [Events] may arrive on the server's own threads.
 */
class FilesLifecycle<S : FilesLifecycle.Server>(
    private val factory: Factory<S>,
    private val newToken: () -> String,
    private val publish: (FilesInfo) -> Unit,
    private val onStatus: () -> Unit,
    private val log: (warn: Boolean, ev: String, fields: String) -> Unit,
) {
    interface Server {
        fun start()
        fun stop()
    }

    interface Events {
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

    @Volatile var status = FilesStatus.DISABLED
        private set

    /** Starts or stops the server for the inputs of [FilesSwitch.shouldRun]. Main thread. */
    fun sync(enabled: Boolean, permission: Boolean, foreground: Boolean, sessionTrusted: Boolean, transport: Transport?) {
        if (FilesSwitch.shouldRun(enabled, permission, foreground, sessionTrusted, transport)) {
            synchronized(lock) { if (server == null) startLocked() }
        } else {
            stop(FilesSwitch.stopReason(enabled, permission, foreground, sessionTrusted))
            setStatus(FilesSwitch.idleStatus(enabled, permission, foreground))
        }
    }

    fun shutdown() = stop("destroy")

    private fun startLocked() {
        val myGen = ++gen
        val token = newToken()
        val s = factory.create(token, object : Events {
            // Publishing happens under the lock (it only posts to a mailbox), so a READY can never overtake the OFF of
            // a stop() that raced with it.
            override fun onListening(port: Int) {
                synchronized(lock) {
                    if (gen != myGen) return
                    publish(FilesInfo(FilesInfo.STATE_READY, port, token))
                    setStatus(FilesStatus.READY)
                }
                log(false, "server", "state=on port=$port")
            }

            override fun onStopped(failed: Boolean) {
                synchronized(lock) {
                    if (gen != myGen) return // stopped on purpose: stop() already reported OFF
                    retired = server
                    server = null
                    publish(FilesInfo.OFF)
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

    private fun stop(reason: String) {
        val s = synchronized(lock) {
            val cur = server ?: return
            server = null
            retired = cur
            gen++ // late callbacks of the old server are ignored
            publish(FilesInfo.OFF) // queued before the listener closes, so the host learns OFF as early as possible
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
