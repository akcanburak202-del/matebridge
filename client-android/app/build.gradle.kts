plugins {
    id("com.android.application")
}

android {
    namespace = "dev.matebridge.client"
    compileSdk = 37

    defaultConfig {
        applicationId = "dev.matebridge.client"
        minSdk = 29
        targetSdk = 31
        versionCode = 1
        versionName = "0.1"
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
}

// Golden vectors live in protocol/fixtures at the repo root; they are read in place, never copied.
tasks.withType<Test>().configureEach {
    systemProperty("matebridge.fixtures", rootProject.file("../protocol/fixtures").absolutePath)
}
