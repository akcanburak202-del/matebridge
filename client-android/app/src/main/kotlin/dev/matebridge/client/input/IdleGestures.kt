package dev.matebridge.client.input

import dev.matebridge.client.idle.IdleChannel
import dev.matebridge.client.idle.IdleDimPolicy
import dev.matebridge.client.idle.IdleSource

/**
 * T-234 (decision 0031): turns the capture frames into the channel view of [IdleDimPolicy.admit]. Pure Kotlin.
 * Each function returns false when the frame must be swallowed (it then goes neither to a tracker nor to the pen overlay).
 *
 *  - touchscreen: one channel per device; engaged and pressed while a finger is down (the frame's finger list after the
 *    event: an UP drops the acting finger, a CANCEL drops all), so an ACTION_DOWN always shows the true state;
 *  - pen: contact is a press; hover keeps the pen engaged but is not a press (it does not stop the counter); UP and CANCEL
 *    are releases and disengage, so a swallowed pen motion ends when the pen is lifted; HOVER_EXIT is a release that keeps
 *    the pen engaged (the policy ends a silent hover swallow after [IdleDimPolicy.LINGER_MS]: the pen left range);
 *  - touchpad: fingers on the pad or a physical button; mouse: a button (motion and wheel are single events);
 *  - keys: one channel per (device, key identity), DOWN to UP, autorepeat included;
 *  - the M-Pencil double tap: a single event.
 */
object IdleGestures {
    fun pen(gate: IdleDimPolicy, f: PenFrame, nowMs: Long): Boolean {
        val ch = IdleChannel.of(IdleChannel.PEN, f.deviceId)
        return when (f.action) {
            PenAction.DOWN, PenAction.MOVE -> gate.admit(ch, IdleSource.PEN, engaged = true, pressed = true, release = false, nowMs = nowMs)
            PenAction.HOVER_ENTER, PenAction.HOVER_MOVE ->
                gate.admit(ch, IdleSource.PEN, engaged = true, pressed = false, release = false, nowMs = nowMs)
            // Android sends HOVER_EXIT right before the tip's DOWN: the pen stays engaged (a swallowed hover lingers briefly).
            PenAction.HOVER_EXIT -> gate.admit(ch, IdleSource.PEN, engaged = true, pressed = false, release = true, nowMs = nowMs)
            PenAction.UP, PenAction.CANCEL ->
                gate.admit(ch, IdleSource.PEN, engaged = false, pressed = false, release = true, nowMs = nowMs)
        }
    }

    fun touch(gate: IdleDimPolicy, f: TouchFrame, nowMs: Long): Boolean {
        val down = when (f.action) {
            TouchAction.DOWN, TouchAction.MOVE -> f.fingers.isNotEmpty()
            TouchAction.UP -> f.fingers.any { it.id != f.actingId }
            TouchAction.CANCEL -> false
        }
        val release = f.action == TouchAction.UP || f.action == TouchAction.CANCEL
        val fresh = f.action == TouchAction.DOWN && f.fingers.all { it.id == f.actingId }
        return gate.admit(IdleChannel.of(IdleChannel.TOUCH, f.deviceId), IdleSource.TOUCH, down, down, release, nowMs, fresh)
    }

    fun pad(gate: IdleDimPolicy, f: PadFrame, nowMs: Long): Boolean {
        val fingers = when (f.action) {
            PadAction.UP -> f.fingers.any { it.id != f.actingId }
            PadAction.CANCEL -> false
            else -> f.fingers.isNotEmpty()
        }
        val held = fingers || f.buttons != 0
        val release = f.action == PadAction.UP || f.action == PadAction.CANCEL ||
            (f.action == PadAction.BUTTON && f.pressedButton == 0)
        return gate.admit(IdleChannel.of(IdleChannel.PAD, f.deviceId), IdleSource.PAD, held, held, release, nowMs)
    }

    fun mouse(gate: IdleDimPolicy, f: MouseFrame, nowMs: Long): Boolean {
        val held = f.buttons != 0
        // A button release under capture carries no motion, no wheel and no press: never swallowed unless its press was.
        val release = !held && f.pressedButton == 0 && f.dx == 0f && f.dy == 0f && f.wheelV == 0f && f.wheelH == 0f
        return gate.admit(IdleChannel.of(IdleChannel.MOUSE, f.deviceId), IdleSource.MOUSE, held, held, release, nowMs)
    }

    fun key(gate: IdleDimPolicy, f: KeyFrame, nowMs: Long): Boolean {
        val id = KeyTracker.keyId(f.scanCode, f.keyCode) ?: 0
        val fresh = f.down && f.repeatCount == 0
        return gate.admit(IdleChannel.of(IdleChannel.KEY, f.deviceId, id), IdleSource.KEY, f.down, f.down, !f.down, nowMs, fresh)
    }

    fun gestureKey(gate: IdleDimPolicy, nowMs: Long): Boolean =
        gate.admit(IdleChannel.of(IdleChannel.GESTURE, 0), IdleSource.GESTURE, engaged = false, pressed = false, release = false, nowMs = nowMs)
}
