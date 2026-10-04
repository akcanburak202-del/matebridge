package dev.matebridge.client.input

/**
 * What finger touches may do (T-223, decisions 0006 and 0030 §1):
 * - [ALL]: today's behaviour (tap, click, drag, two-finger scroll and pinch).
 * - [GESTURES_ONLY]: Çizim's temporary policy. One finger sends nothing (a palm cannot click or drag), but two-finger
 *   scroll and pinch (canvas pan and zoom) still reach the Mac.
 * - [OFF]: the stored setting "Parmak dokunmasını tamamen kapat": every finger is refused.
 */
enum class FingerPolicy(val id: String) { ALL("all"), GESTURES_ONLY("gestures"), OFF("off") }
