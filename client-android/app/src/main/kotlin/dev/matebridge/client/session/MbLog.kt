package dev.matebridge.client.session

import android.os.SystemClock
import android.util.Log

/**
 * Runtime log lines per docs/LOGGING.md: `<mono_ms> <LEVEL> <component> sid= gen= ev= key=value ...`
 * on logcat tag `MB/<component>`. Never pass device/host names, text or key characters as fields.
 */
object MbLog {
    /** Session id (0 = none) and control generation of the current session, set by the controller. */
    @Volatile var sid: Long = 0
    @Volatile var gen: Int = 0

    fun format(monoMs: Long, level: Char, component: String, sid: Long, gen: Int, ev: String, fields: String): String {
        val tail = if (fields.isEmpty()) "" else " $fields"
        return "$monoMs $level $component sid=$sid gen=$gen ev=$ev$tail"
    }

    fun i(ev: String, fields: String = "", component: String = "session") = emit('I', component, ev, fields)
    fun w(ev: String, fields: String = "", component: String = "session") = emit('W', component, ev, fields)
    fun e(ev: String, fields: String = "", component: String = "session") = emit('E', component, ev, fields)

    private fun emit(level: Char, component: String, ev: String, fields: String) {
        val line = format(SystemClock.elapsedRealtime(), level, component, sid, gen, ev, fields)
        val tag = "MB/$component"
        when (level) {
            'E' -> Log.e(tag, line)
            'W' -> Log.w(tag, line)
            else -> Log.i(tag, line)
        }
    }
}
