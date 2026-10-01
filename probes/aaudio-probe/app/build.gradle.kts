plugins {
    id("com.android.application")
}

android {
    namespace = "dev.matebridge.aaudioprobe"
    compileSdk = 37
    // T-099: installed with sdkmanager into ~/Library/Android/sdk (stable channel).
    ndkVersion = "30.0.16248370"

    defaultConfig {
        applicationId = "dev.matebridge.aaudioprobe"
        minSdk = 29
        targetSdk = 31
        versionCode = 1
        versionName = "0.1"
        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                cppFlags += listOf("-std=c++17", "-Wall", "-Werror")
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
