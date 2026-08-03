plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.espflash_flutter"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.espflash_flutter"
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // Force arm64-v8a only (mirrors happy_flutter): covers every modern
        // phone; the USB host API needs OTG-capable hardware anyway.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
    }

    val keystorePath = System.getenv("KEYSTORE_PATH")
    signingConfigs {
        create("release") {
            if (!keystorePath.isNullOrBlank()) {
                storeFile = file(keystorePath)
                storePassword = System.getenv("KEYSTORE_STORE_PASSWORD")
                keyPassword = System.getenv("KEYSTORE_KEY_PASSWORD")
                keyAlias = System.getenv("KEYSTORE_KEY_ALIAS")
            }
        }
    }

    buildTypes {
        getByName("debug") {
            isMinifyEnabled = false
            if (!keystorePath.isNullOrBlank()) {
                signingConfig = signingConfigs.findByName("release")
            }
        }
        getByName("release") {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (!keystorePath.isNullOrBlank()) {
                signingConfig = signingConfigs.findByName("release")
            } else {
                // Fall back to the debug key so `flutter build apk --release`
                // works out of the box; CI injects a real keystore via env.
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }

    packagingOptions {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }
}

kotlin {
    jvmToolchain(17)
}

flutter {
    source = "../.."
}

dependencies {
    // ESP32 flashing talks to USB serial bridges (CP210x / CH34x / CDC-ACM).
    implementation("com.github.mik3y:usb-serial-for-android:3.11.0")
    testImplementation("junit:junit:4.13.2")
}
