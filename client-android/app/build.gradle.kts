import com.android.build.api.variant.BuildConfigField
import java.io.ByteArrayOutputStream
import java.time.Duration
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import javax.inject.Inject

plugins {
    id("com.android.application")
}

/**
 * T-146: build identity read from git. Gradle evaluates it lazily when the task that needs it runs (never at
 * configuration time), so the configuration cache stays valid and a tree without `.git` (or without a `git` binary)
 * still builds: the SHA falls back to "unknown" and versionCode to 1.
 */
abstract class BuildIdentity @Inject constructor(private val exec: ExecOperations) :
    ValueSource<String, BuildIdentity.Params> {
    interface Params : ValueSourceParameters {
        /** "sha" (short SHA, "-dirty" suffix), "count" (commits up to HEAD), "minutes" (build time, minutes since 2026-01-01 UTC) or "time" (UTC build time, minutes). */
        val what: Property<String>
        val dir: DirectoryProperty
    }

    override fun obtain(): String = when (parameters.what.get()) {
        "sha" -> git("rev-parse", "--short", "HEAD")?.takeIf { it.isNotEmpty() }?.let { sha ->
            val status = git("status", "--porcelain")
            if (status.isNullOrEmpty()) sha else "$sha-dirty"
        } ?: "unknown"
        "count" -> git("rev-list", "--count", "HEAD")?.toIntOrNull()?.takeIf { it > 0 }?.toString() ?: "1"
        // T-301: monotonic versionCode = minutes since 2026-01-01 UTC.
        "minutes" -> Duration.between(
            ZonedDateTime.of(2026, 1, 1, 0, 0, 0, 0, ZoneOffset.UTC), ZonedDateTime.now(ZoneOffset.UTC),
        ).toMinutes().toString()
        else -> ZonedDateTime.now(ZoneOffset.UTC).format(DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm'Z'"))
    }

    private fun git(vararg args: String): String? = try {
        val out = ByteArrayOutputStream()
        val result = exec.exec {
            workingDir = parameters.dir.get().asFile
            commandLine(listOf("git") + args)
            standardOutput = out
            errorOutput = ByteArrayOutputStream()
            isIgnoreExitValue = true
        }
        if (result.exitValue == 0) out.toString(Charsets.UTF_8).trim() else null
    } catch (e: Exception) {
        null // no git binary
    }
}

fun buildIdentity(what: String): Provider<String> = providers.of(BuildIdentity::class) {
    parameters.what.set(what)
    parameters.dir.set(layout.projectDirectory)
}

android {
    namespace = "dev.matebridge.client"
    compileSdk = 37
    // Decision 0012 / T-100: AAudio output in C++ (src/main/cpp). Install with sdkmanager "ndk;30.0.16248370" "cmake;4.1.2".
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "dev.matebridge.client"
        minSdk = 31
        targetSdk = 31
        // T-146/T-301: the real versionCode is build-time minutes, set per variant below; 1 is the no-git fallback.
        versionCode = 1
        versionName = "0.1"
        ndk {
            // The tablet only (MatePad Pro 12.2); no emulator ABIs.
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17", "-Wall", "-Wextra", "-Werror")
            }
        }
    }

    buildFeatures {
        buildConfig = true
    }

    lint {
        // lintVital runs for every non-debuggable build and fails on the deliberate targetSdk 31 (ExpiredTargetSdkVersion,
        // a Play Store rule; this app is sideloaded). Debug builds never ran it; the daily build keeps parity.
        checkReleaseBuilds = false
    }

    buildTypes {
        // T-301 / decision 0037: the everyday build. Not debuggable (ART optimises, native code is Release), signed with
        // the debug key so it updates the installed debug app in place (pairing keys survive), profileable via the
        // manifest. R8 stays off. applicationId and versionCode rules are shared with debug.
        create("daily") {
            initWith(getByName("debug"))
            isDebuggable = false
            isJniDebuggable = false
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "debug"
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
}

androidComponents {
    onVariants { variant ->
        // T-301: versionCode is build-time minutes, not the commit count: a non-debuggable app cannot be downgraded, and
        // worktree branches have fewer commits than main. The commit stays in versionName, BuildConfig.GIT_SHA and app_start.
        val versionCode = buildIdentity("minutes").map { it.toInt() }
        val versionName = buildIdentity("sha").map { "0.1-$it" }
        variant.outputs.forEach {
            it.versionCode.set(versionCode)
            it.versionName.set(versionName)
        }
        variant.buildConfigFields?.put(
            "GIT_SHA",
            buildIdentity("sha").map { BuildConfigField("String", "\"$it\"", "Short commit SHA, -dirty suffix, or unknown (T-146)") },
        )
        variant.buildConfigFields?.put(
            "BUILD_TIME_UTC",
            buildIdentity("time").map { BuildConfigField("String", "\"$it\"", "UTC build time, minute precision (T-146)") },
        )
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// Golden vectors live in protocol/fixtures at the repo root; they are read in place, never copied.
tasks.withType<Test>().configureEach {
    systemProperty("matebridge.fixtures", rootProject.file("../protocol/fixtures").absolutePath)
}
