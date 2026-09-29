package dev.matebridge.probe.input

/** Converts records to single-line JSON (JSON Lines). No external dependencies. */
object EventJson {

    fun motion(r: MotionRecord): String = obj {
        str("type", "motion")
        num("t", r.t)
        str("cb", r.callback)
        bool("captured", r.captured)
        str("action", r.action)
        num("actionMasked", r.actionMasked)
        num("actionIndex", r.actionIndex)
        num("actionButton", r.actionButton)
        num("buttonState", r.buttonState)
        num("source", r.source)
        str("sourceHex", r.sourceHex)
        num("deviceId", r.deviceId)
        strOrNull("device", r.deviceName)
        num("pointerCount", r.pointerCount)
        num("eventTime", r.eventTime)
        num("downTime", r.downTime)
        num("historySize", r.historySize)
        raw("pointers", array(r.pointers.map { pointer(it) }))
        raw(
            "history",
            array(
                r.history.map { h ->
                    obj {
                        num("eventTime", h.eventTime)
                        raw("pointers", array(h.pointers.map { pointer(it) }))
                    }
                },
            ),
        )
    }

    fun key(r: KeyRecord): String = obj {
        str("type", "key")
        num("t", r.t)
        str("action", r.action)
        num("keyCode", r.keyCode)
        str("keyName", r.keyName)
        num("scanCode", r.scanCode)
        num("metaState", r.metaState)
        num("repeatCount", r.repeatCount)
        num("flags", r.flags)
        num("source", r.source)
        num("deviceId", r.deviceId)
        strOrNull("device", r.deviceName)
        num("eventTime", r.eventTime)
        num("downTime", r.downTime)
    }

    /** Free-form marker record, e.g. session start or pointer-capture change. */
    fun meta(t: Long, name: String, fields: Map<String, Any?> = emptyMap()): String = obj {
        str("type", "meta")
        num("t", t)
        str("name", name)
        for ((k, v) in fields) {
            when (v) {
                null -> raw(k, "null")
                is Boolean -> bool(k, v)
                is Float, is Double -> raw(k, number((v as Number).toDouble()))
                is Number -> num(k, v)
                else -> str(k, v.toString())
            }
        }
    }

    private fun pointer(p: PointerSample): String = obj {
        num("id", p.id)
        str("tool", p.toolType)
        flt("x", p.x)
        flt("y", p.y)
        flt("pressure", p.pressure)
        flt("size", p.size)
        flt("tilt", p.tilt)
        flt("orientation", p.orientation)
        flt("distance", p.distance)
        flt("relX", p.relX)
        flt("relY", p.relY)
        flt("vscroll", p.vScroll)
        flt("hscroll", p.hScroll)
    }

    // ---- minimal JSON building ----

    private class Builder {
        private val sb = StringBuilder("{")
        private var first = true

        private fun key(k: String) {
            if (!first) sb.append(',')
            first = false
            sb.append('"').append(escape(k)).append("\":")
        }

        fun str(k: String, v: String) { key(k); sb.append('"').append(escape(v)).append('"') }
        fun strOrNull(k: String, v: String?) { if (v == null) raw(k, "null") else str(k, v) }
        fun num(k: String, v: Number) { key(k); sb.append(v.toString()) }
        fun flt(k: String, v: Float) {
            key(k)
            sb.append(if (v.isNaN() || v.isInfinite()) "null" else v.toString())
        }
        fun bool(k: String, v: Boolean) { key(k); sb.append(v) }
        fun raw(k: String, json: String) { key(k); sb.append(json) }
        fun build(): String = sb.append('}').toString()
    }

    private fun obj(block: Builder.() -> Unit): String = Builder().apply(block).build()

    private fun array(items: List<String>): String = items.joinToString(",", "[", "]")

    /** NaN/Infinity are not valid JSON, emit null. */
    internal fun number(v: Double): String = if (v.isNaN() || v.isInfinite()) "null" else v.toString()

    internal fun escape(s: String): String {
        val sb = StringBuilder(s.length + 8)
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c < ' ' -> sb.append(String.format("\\u%04x", c.code))
                else -> sb.append(c)
            }
        }
        return sb.toString()
    }
}
