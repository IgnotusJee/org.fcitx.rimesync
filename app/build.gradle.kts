plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.fcitx.rimesync"
    compileSdk = 35

    defaultConfig {
        applicationId = "org.fcitx.rimesync"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        jvmToolchain(17)
    }
}

dependencies {
    // Xposed API (compileOnly - not packaged, target app provides it)
    compileOnly("io.github.libxposed:api:101.0.1")
}
