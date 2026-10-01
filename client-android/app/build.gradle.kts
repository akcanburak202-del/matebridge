plugins {
    id("com.android.application")
}

android {
    namespace = "dev.matebridge.client"
    compileSdk = 37
    // Decision 0012 / T-100: AAudio output in C++ (src/main/cpp). Install with sdkmanager "ndk;30.0.16248370" "cmake;4.1.2".
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "dev.matebridge.client"
        minSdk = 29
        targetSdk = 31
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

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "4.1.2"
        }
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// Golden vectors live in protocol/fixtures at the repo root; they are read in place, never copied.
tasks.withType<Test>().configureEach {
    systemProperty("matebridge.fixtures", rootProject.file("../protocol/fixtures").absolutePath)
}
