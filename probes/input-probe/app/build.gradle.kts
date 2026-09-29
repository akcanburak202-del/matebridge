plugins {
    id("com.android.application")
}

android {
    namespace = "dev.matebridge.probe.input"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.matebridge.probe.input"
        minSdk = 29
        targetSdk = 31
        versionCode = 1
        versionName = "0.1"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}
