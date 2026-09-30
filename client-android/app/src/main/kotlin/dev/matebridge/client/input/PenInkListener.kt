package dev.matebridge.client.input

/**
 * Local, display-only tap on the pen stream (T-056): [InputCapture] hands every accepted pen frame to it on the UI
 * thread, before any network work, so a local indicator can follow the pen without waiting for the Mac round trip.
 * It never influences what is sent.
 */
interface PenInkListener {
    /** A pen frame (all samples, oldest first). [eraser] is true for the eraser tip or the local eraser-mode mirror. */
    fun onPenFrame(f: PenFrame, eraser: Boolean)

    /** Input was released, suspended or reset: forget any trail and hide the dot. */
    fun onPenClear()
}
