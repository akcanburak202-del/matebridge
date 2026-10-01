package dev.matebridge.client.video

import android.content.Context
import android.os.Build
import android.os.PerformanceHintManager

/** [PerfHint.Backend] over `PerformanceHintManager` (API 31, T-079). */
@android.annotation.TargetApi(31)
class AndroidPerfHint private constructor(private val manager: PerformanceHintManager) : PerfHint.Backend {
    companion object {
        /** Null when the platform has no hint manager (API < 31, or the service is missing as on some ROMs). */
        fun create(context: Context): PerfHint.Backend? {
            if (Build.VERSION.SDK_INT < 31) return null
            val m = try { context.getSystemService(PerformanceHintManager::class.java) } catch (_: Exception) { null }
            return m?.let { AndroidPerfHint(it) }
        }
    }

    override val preferredUpdateRateNs: Long
        get() = try { manager.preferredUpdateRateNanos } catch (_: Exception) { -1L }

    override fun createSession(tids: IntArray, targetNs: Long): PerfHint.Session? {
        val s = manager.createHintSession(tids, targetNs) ?: return null
        return object : PerfHint.Session {
            override fun updateTargetWorkDuration(targetNs: Long) = s.updateTargetWorkDuration(targetNs)
            override fun reportActualWorkDuration(actualNs: Long) = s.reportActualWorkDuration(actualNs)
            override fun close() = s.close()
        }
    }
}
