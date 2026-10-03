package dev.matebridge.client.session

/**
 * T-160 (red step): today's video delivery rule, extracted unchanged. A frame is delivered whenever its connection's
 * `config_id` equals the last applied STREAM_CONFIG's; connection generation, session and the renderer's installed
 * config are not checked. The fix follows in the next commit.
 */
class VideoDeliveryGate {
    @Volatile private var appliedConfigId = -1

    /** config_id of the latest applied STREAM_CONFIG (-1 = none). */
    val currentConfigId: Int get() = appliedConfigId

    /** Engine thread: the gate's part of a machine action. */
    fun onAction(a: SessionMachine.Action) {
        if (a is SessionMachine.Action.ApplyConfig) appliedConfigId = a.config.configId
    }

    /** `VideoConn.abort()`. */
    @Suppress("UNUSED_PARAMETER")
    fun close(gen: Int) {}

    /** UI: the renderer has installed [config]. */
    @Suppress("UNUSED_PARAMETER")
    fun install(config: Any) {}

    /** Reader thread: runs [block] when the frame may be delivered; returns whether it ran. */
    @Suppress("UNUSED_PARAMETER")
    fun deliver(gen: Int, configId: Int, block: () -> Unit): Boolean {
        if (configId != appliedConfigId) return false
        block()
        return true
    }
}
