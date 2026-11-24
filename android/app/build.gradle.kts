import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release signing: keystore.properties (local, git-ignored) or SIMBRIDGE_* env vars (CI secrets).
val signingProps = Properties().apply {
    val f = rootProject.file("keystore.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
fun signingValue(key: String, env: String): String? =
    signingProps.getProperty(key) ?: System.getenv(env)?.takeIf { it.isNotBlank() }

android {
    namespace = "app.simbridge.android"
    compileSdk = 35

    defaultConfig {
        applicationId = "app.simbridge.android"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"
    }

    signingConfigs {
        val storePath = signingValue("storeFile", "SIMBRIDGE_KEYSTORE")
        if (storePath != null && file(storePath).exists()) {
            create("release") {
                storeFile = file(storePath)
                storePassword = signingValue("storePassword", "SIMBRIDGE_KEYSTORE_PASSWORD")
                keyAlias = signingValue("keyAlias", "SIMBRIDGE_KEY_ALIAS")
                keyPassword = signingValue("keyPassword", "SIMBRIDGE_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    lint {
        abortOnError = false
        checkReleaseBuilds = false
        textReport = true
        textOutput = file("build/reports/lint-results-release.txt")
    }
    packaging {
        resources.excludes += setOf("/META-INF/{AL2.0,LGPL2.1}", "META-INF/versions/9/OSGI-INF/MANIFEST.MF")
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("org.java-websocket:Java-WebSocket:1.5.7")
    implementation("com.google.zxing:core:3.5.3")
    // Developer-mode call audio (no root): Shizuku gives ADB-level privileges to the app.
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")
    // Built-in alternative to Shizuku: talk to the phone's own Wireless debugging (adbd) directly.
    implementation("com.github.MuntashirAkon:libadb-android:3.1.1")
    implementation("com.github.MuntashirAkon:sun-security-android:1.1")
    implementation("org.conscrypt:conscrypt-android:2.5.3")
}
