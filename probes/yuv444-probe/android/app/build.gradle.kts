plugins {
    id("com.android.application")
}

android {
    namespace = "dev.matebridge.yuv444probe"
    compileSdk = 37
    // Same NDK / CMake as client-android (decision 0012); probe-only native code in src/main/cpp.
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "dev.matebridge.yuv444probe"
        minSdk = 29
        targetSdk = 31
        versionCode = 1
        versionName = "0.1"
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17", "-Wall", "-Wextra")
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
