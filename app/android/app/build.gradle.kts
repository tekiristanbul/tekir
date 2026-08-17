import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (issue #85): android/key.properties is gitignored and
// holds the upload-keystore coordinates (see key.properties.example).
// When it exists, `flutter build appbundle` produces the Play-ready
// artifact with no code changes; when absent, release falls back to the
// debug key so local `flutter run --release` keeps working.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}

// Google Maps SDK for Android reads its key from a manifest meta-data entry,
// filled in from the gitignored android/maps.properties (see
// maps.properties.example) — same posture as the ios GoogleMaps.xcconfig.
// Debug/profile builds stay buildable without it (the map renders blank and
// the sdk logs an authorization failure); release builds fail fast below
// rather than shipping a keyless artifact to play.
val mapsApiKey: String =
    Properties()
        .apply {
            val f = rootProject.file("maps.properties")
            if (f.exists()) f.inputStream().use { load(it) }
        }
        .getProperty("GOOGLE_MAPS_API_KEY")
        ?.trim()
        .orEmpty()

tasks.configureEach {
    if (name == "preReleaseBuild" || name == "bundleRelease" || name == "assembleRelease") {
        doFirst {
            if (mapsApiKey.isEmpty()) {
                throw GradleException(
                    "Google Maps Android API key is missing. Copy " +
                        "app/android/maps.properties.example to " +
                        "app/android/maps.properties and set GOOGLE_MAPS_API_KEY. " +
                        "See DEVELOPMENT.md > \"google maps sdk (android)\".",
                )
            }
        }
    }
}

// Firebase on android needs app/google-services.json, which is not committed
// (same as the ios GoogleService-Info.plist). Applying the plugin
// unconditionally would break a fresh clone, so key it off the file.
if (rootProject.file("app/google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "istanbul.tekir"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // play store package id — matches the ios bundle id (reverse of tekir.istanbul)
        applicationId = "istanbul.tekir"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["googleMapsApiKey"] = mapsApiKey
    }

    signingConfigs {
        if (keystoreProperties.isNotEmpty()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystoreProperties.isNotEmpty()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
