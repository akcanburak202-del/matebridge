package dev.matebridge.client

/**
 * Which client build is running (T-146): the `ev=app_start` log line and the settings "Sürüm" row. Pure Kotlin over raw
 * values so the JVM test needs no Android; [current] reads the generated BuildConfig.
 *
 * Privacy (AGENTS.md): only build and OS release identifiers. Never a serial number, ANDROID_ID, device id or host name.
 */
class BuildInfo(versionName: String?, sha: String?, builtUtc: String?) {
    val versionName = clean(versionName)
    val sha = clean(sha)
    val builtUtc = clean(builtUtc)

    /** `version=… sha=… built=… sdk=… os_build=…`, in that order. [osBuild] is `Build.DISPLAY`. */
    fun logFields(sdk: Int, osBuild: String?): String =
        "version=$versionName sha=$sha built=$builtUtc sdk=$sdk os_build=${clean(osBuild)}"

    /** "Sürüm: 0.1 (abc1234, 2026-10-03T12:34Z)". */
    fun settingsText(): String = "Sürüm: $versionName ($sha, $builtUtc)"

    companion object {
        const val UNKNOWN = "unknown"

        private val appStartLogged = java.util.concurrent.atomic.AtomicBoolean(false)

        /** True exactly once per process, so an activity recreated by a config change does not log `app_start` again. */
        fun claimAppStart(): Boolean = appStartLogged.compareAndSet(false, true)

        val current: BuildInfo by lazy { BuildInfo(BuildConfig.VERSION_NAME, BuildConfig.GIT_SHA, BuildConfig.BUILD_TIME_UTC) }

        /** Blank → [UNKNOWN]; whitespace inside → `_`, so each value stays one key=value token. */
        fun clean(v: String?): String {
            val t = v?.trim().orEmpty()
            return if (t.isEmpty()) UNKNOWN else t.replace(Regex("\\s+"), "_")
        }
    }
}
