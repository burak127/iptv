import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is loaded from android/key.properties (git-ignored). When it's
// absent — a fresh checkout, CI, or a quick local `--release` run — we fall back
// to the debug keystore so the build still succeeds. To ship an updatable /
// Play-uploadable build, create a keystore and android/key.properties with
// storeFile, storePassword, keyAlias, keyPassword.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.iptvplayer.iptv_player"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.iptvplayer.iptv_player"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = (keystoreProperties["storeFile"] as String?)?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Real upload key when key.properties exists; debug otherwise so
            // local release runs still work (but such an APK isn't distributable).
            signingConfig = if (hasReleaseKeystore)
                signingConfigs.getByName("release")
            else
                signingConfigs.getByName("debug")
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

dependencies {
    // ExoPlayer (Media3) for the native SurfaceView live-video path — renders
    // the hardware decoder straight onto a SurfaceView overlay (like TiviMate),
    // bypassing Flutter's texture composite that stutters on weak Amlogic boxes.
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-datasource:1.4.1")
    // NotificationCompat/ActivityCompat/ContextCompat for BootReceiver's
    // full-screen-intent fallback and its notification-permission request.
    // Almost certainly already present transitively via the Flutter Android
    // embedding, but declared explicitly so that isn't an assumption.
    implementation("androidx.core:core-ktx:1.13.1")
}
