package dev.matebridge.client.input

import dev.matebridge.client.protocol.Message

/*
 * MotionEvent-independent intermediate model for pen and touch capture (T-024). Everything in this
 * package except MotionEventAdapter is plain Kotlin and JVM-tested. All of it runs on the UI thread
 * (PROTOCOL.md section 7: a single ordered FIFO fed from one thread).
 *
 * Clocks: event times are `MotionEvent.eventTime * 1000` (uptime, CLOCK_MONOTONIC, the same base as
 * System.nanoTime) in microseconds; "now" values are `SystemClock.uptimeMillis()` in milliseconds.
 */

/**
 * The single control FIFO towards the host. [send] must be non-blocking and order-preserving; it
 * returns false when the message was refused (no accepted session, closed, or the bounded queue
 * overflowed, in which case the connection is being torn down and the host releases all input).
 */
interface InputSink {
    fun send(msg: Message): Boolean

    /** True while the send queue is backed up enough that mergeable messages should be held (PROTOCOL.md section 5). */
    fun congested(): Boolean

    /**
     * Tear the control connection down so the host releases all input on disconnect (PROTOCOL.md section 7).
     * Called when a RELEASE_ALL could not be queued. Must be harmless when there is no accepted session.
     */
    fun closeConnection()
}

/**
 * A message plus whether it may be merged with an adjacent mergeable message of the same kind while
 * the queue is congested: only hover PEN samples that repeat an already-sent hover state, and
 * SCROLL CHANGED (PROTOCOL.md section 5). Everything else is a state transition and is never merged or dropped.
 */
class Outgoing(val msg: Message, val mergeable: Boolean = false)

/** What the tablet pen is doing right now; the finger gate reads it (decision 0006, PROTOCOL.md section 7). */
interface PenPresence {
    /** Pen believed to be in hover range or touching. */
    val inRange: Boolean

    /**
     * Uptime ms at which the last PEN message was emitted, liveness repeats and synthetic `flags = 0` included.
     * This is the host's gate clock ("1 s after the last PEN message"), not the last real Android pen event.
     */
    val lastSentMs: Long
}

enum class PenAction { DOWN, MOVE, UP, CANCEL, HOVER_ENTER, HOVER_MOVE, HOVER_EXIT }

/** Coarse tool classification of a pointer, done by the Android adapter (`TOOL_TYPE_*`). */
enum class ToolKind { PEN, FINGER, OTHER }

enum class Route { PEN, TOUCH, NONE }

/** "No device": the trackers follow nothing. */
const val NO_DEVICE = Int.MIN_VALUE

/**
 * What the trackers currently follow. Android pointer ids are unique only within one input device's gesture, and on
 * the MatePad the pen (`huawei,ts_pen`) and the touchscreen are separate devices that both number their pointers
 * from 0, so a pointer is always identified by the pair (deviceId, pointerId).
 */
interface PointerFollowers {
    /** The pen tracker holds an open contact opened by exactly this pointer of this device. */
    fun followsPen(deviceId: Int, pointerId: Int): Boolean

    /** The finger tracker holds state (pending, pressed, scrolling, parked) for exactly this pointer of this device. */
    fun followsFinger(deviceId: Int, pointerId: Int): Boolean

    /** Device of the open pen contact, or [NO_DEVICE]. */
    val penContactDevice: Int

    /** Device of the finger gesture (or of the lockout after a scroll) the finger tracker holds, or [NO_DEVICE]. */
    val touchDevice: Int
}

/**
 * Where a release (`ACTION_UP` / `ACTION_POINTER_UP` / `ACTION_CANCEL`) goes (PROTOCOL.md section 7: releases do not
 * depend on the tool type at release time, and they belong to the (device, pointer) pair that was pressed).
 *  - UP / POINTER_UP: the tracker that follows exactly this (device, pointer) wins over whatever tool type the platform
 *    reports now, so a release reported as PALM or UNKNOWN still ends the right press, and a palm on the touchscreen
 *    that shares pointer id 0 with the pen contact never ends the stroke. Nobody follows it: the reported tool type
 *    decides (a pen release ends the pen's active tool, a finger release goes to touch); an OTHER tool is ignored.
 *  - CANCEL ends only what belongs to the cancelled event's device.
 */
object ReleaseRouting {
    fun routeUp(kind: ToolKind, deviceId: Int, pointerId: Int, followers: PointerFollowers): Route = when {
        followers.followsPen(deviceId, pointerId) -> Route.PEN
        followers.followsFinger(deviceId, pointerId) -> Route.TOUCH
        kind == ToolKind.PEN -> Route.PEN
        kind == ToolKind.FINGER -> Route.TOUCH
        else -> Route.NONE
    }

    /** The pen contact is cancelled by a cancel that carries a pen pointer or comes from the contact's device. */
    fun cancelReachesPen(deviceId: Int, penPointerInEvent: Boolean, followers: PointerFollowers) =
        penPointerInEvent || followers.penContactDevice == deviceId

    /** The finger gesture is cancelled by a cancel that carries a finger pointer or comes from the gesture's device. */
    fun cancelReachesTouch(deviceId: Int, fingerPointerInEvent: Boolean, followers: PointerFollowers) =
        fingerPointerInEvent || followers.touchDevice == deviceId
}

/**
 * One digitizer sample. [x]/[y] are pixels in the coordinate space of `VideoViewport` (root/window
 * content). [tiltRad] = AXIS_TILT, [orientationRad] = AXIS_ORIENTATION.
 */
class PenPoint(
    val timeUs: Long,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltRad: Float,
    val orientationRad: Float,
    val button: Boolean = false,
)

/**
 * A pen MotionEvent: all historical samples followed by the current one, oldest first (never empty).
 * [action] DOWN/MOVE/UP/CANCEL come from touch events (stylus in contact), HOVER_* from generic motion events.
 */
class PenFrame(
    val action: PenAction,
    val eraser: Boolean,
    val points: List<PenPoint>,
    val deviceId: Int = 0,
    /** Android pointer id of the pen; the tracker remembers the one that went down so releases can be routed by id. */
    val pointerId: Int = 0,
)

enum class TouchAction { DOWN, MOVE, UP, CANCEL }

class Finger(val id: Int, val x: Float, val y: Float)

/**
 * A finger MotionEvent. [actingId] is the pointer id that went down or up (DOWN/UP only);
 * [fingers] holds the current position of every finger pointer in the event, including the acting one.
 */
class TouchFrame(
    val action: TouchAction,
    val actingId: Int,
    val fingers: List<Finger>,
    val timeUs: Long,
    val deviceId: Int = 0,
)

/** Per-second counters for the `MB/input` summary (no coordinates, no key data). */
class InputCounters {
    var penSamples = 0L
    var penMsgs = 0L
    var touchMsgs = 0L
    var otherMsgs = 0L
    var palmRejects = 0L
    var merged = 0L
    var refused = 0L
    var tiltHeld = 0L
    var hoverStale = 0L
    var contactStale = 0L
    var exitAbsorbed = 0L
    var invalid = 0L
    var pressStale = 0L
    var scrollIdleEnds = 0L

    fun any() = penSamples + penMsgs + touchMsgs + otherMsgs + palmRejects + merged + refused +
        tiltHeld + hoverStale + contactStale + exitAbsorbed + invalid + pressStale + scrollIdleEnds > 0

    fun fields(intervalMs: Long) =
        "interval_ms=$intervalMs pen_samples=$penSamples pen_msgs=$penMsgs touch_msgs=$touchMsgs other_msgs=$otherMsgs " +
            "palm_reject=$palmRejects merged=$merged refused=$refused tilt_held=$tiltHeld hover_stale=$hoverStale " +
            "contact_stale=$contactStale exit_absorbed=$exitAbsorbed invalid=$invalid press_stale=$pressStale " +
            "scroll_idle_end=$scrollIdleEnds"

    fun reset() {
        penSamples = 0; penMsgs = 0; touchMsgs = 0; otherMsgs = 0; palmRejects = 0; merged = 0; refused = 0
        tiltHeld = 0; hoverStale = 0; contactStale = 0; exitAbsorbed = 0; invalid = 0; pressStale = 0; scrollIdleEnds = 0
    }
}

/** "Never" timestamp that stays safe under subtraction. */
internal const val NEVER_MS = Long.MIN_VALUE / 4
