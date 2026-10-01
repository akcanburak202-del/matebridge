package dev.matebridge.client.session

/** How the tablet reaches the Mac: over `adb reverse` on loopback (USB) or via LAN discovery / manual address (Wi-Fi). */
enum class Transport(val logName: String) {
    USB("usb"), WIFI("wifi");

    companion object {
        fun parse(s: String?): Transport = if (s == "usb") USB else WIFI
    }
}

/** Pure decisions for the USB / Wi-Fi connection choice (PROTOCOL.md section 3.1). */
object ConnectMode {
    const val USB_HOST = "127.0.0.1"
    const val USB_CONTROL_PORT = 47001
    const val USB_TIMEOUT_MS = 3000L

    val usbEndpoint = Endpoint(USB_HOST, USB_CONTROL_PORT)

    /** Loopback control address means the connection goes through `adb reverse`. */
    fun transportOf(ep: Endpoint): Transport =
        if (ep.host == USB_HOST || ep.host == "localhost") Transport.USB else Transport.WIFI

    /** NSD discovery may auto-connect only in Wi-Fi mode. */
    fun autoDiscover(mode: Transport) = mode == Transport.WIFI

    /**
     * Show "USB link missing" once the manual USB mode has been trying for [USB_TIMEOUT_MS] without reaching the host
     * (still waiting for the connection, or it dropped/failed) and no session is established. AUTO falls back to
     * Wi-Fi instead (T-096), so it never shows the hint.
     */
    fun showUsbHint(mode: TransportMode, elapsedMs: Long, hostReached: Boolean) =
        mode == TransportMode.USB && !hostReached && elapsedMs >= USB_TIMEOUT_MS
}
