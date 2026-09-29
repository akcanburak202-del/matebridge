package dev.matebridge.probe.input

/** One pointer's axes at one instant. Plain data so the JSON conversion is JVM-testable. */
data class PointerSample(
    val id: Int,
    val toolType: String,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val size: Float,
    val tilt: Float,
    val orientation: Float,
    val distance: Float,
    val relX: Float,
    val relY: Float,
    val vScroll: Float,
    val hScroll: Float,
)

/** A batched (historical) sample: all pointers at an earlier event time. */
data class HistorySample(val eventTime: Long, val pointers: List<PointerSample>)

data class MotionRecord(
    val t: Long, // elapsedRealtime ms when we received it
    val callback: String, // "touch", "generic", "captured"
    val captured: Boolean,
    val action: String,
    val actionMasked: Int,
    val actionIndex: Int,
    val actionButton: Int,
    val buttonState: Int,
    val source: Int,
    val sourceHex: String,
    val deviceId: Int,
    val deviceName: String?,
    val pointerCount: Int,
    val eventTime: Long,
    val downTime: Long,
    val historySize: Int,
    val pointers: List<PointerSample>,
    val history: List<HistorySample>,
)

/** Key events carry codes only. Never the produced character (privacy rule). */
data class KeyRecord(
    val t: Long,
    val action: String,
    val keyCode: Int,
    val keyName: String,
    val scanCode: Int,
    val metaState: Int,
    val repeatCount: Int,
    val flags: Int,
    val source: Int,
    val deviceId: Int,
    val deviceName: String?,
    val eventTime: Long,
    val downTime: Long,
)
