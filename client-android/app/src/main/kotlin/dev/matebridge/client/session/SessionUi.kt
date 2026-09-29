package dev.matebridge.client.session

/** What the screen shows. Produced by [SessionMachine] (and "Searching" by the UI layer). */
sealed interface SessionUi {
    data object Idle : SessionUi
    data object Searching : SessionUi
    data class Connecting(val endpoint: Endpoint) : SessionUi
    data class AwaitingApproval(val hostName: String) : SessionUi
    data class Connected(val hostName: String, val framesReceived: Long) : SessionUi

    /** "Bağlantı yok"; an automatic retry follows in [retryInMs]. */
    data class Disconnected(val cause: Cause, val retryInMs: Long) : SessionUi

    /** Terminal until the user retries: no automatic reconnect. */
    data class Failed(val cause: Cause) : SessionUi

    enum class Cause { LOST, HOST_CLOSED, BUSY, REJECTED, VERSION_MISMATCH, PROTOCOL_ERROR, CONNECT_FAILED }
}
