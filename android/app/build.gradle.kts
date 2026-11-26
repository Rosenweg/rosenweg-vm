plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ch.rosenweg4303.vm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "ch.rosenweg4303.vm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Nur die ABIs, fuer die es den nativen Stapel gibt (native/spice-stapel):
        // Telefone (arm64) und der Emulator (x86_64).
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // librwspice.so, libspiceglib.so, librwtunnel.so je ABI; zusammengestellt
    // von android/native-sammeln.sh (lokal) bzw. dem Workflow android.yml.
    sourceSets["main"].jniLibs.srcDir("${rootDir}/../build/android-jniLibs")

    // Rosenweg-Signierschluessel nur ueber Umgebungsvariablen (CI-Secrets,
    // siehe .github/workflows/android.yml; lokal aus keystore.properties
    // gesetzt). Ohne sie: Debug-Signatur, damit `flutter run --release` und
    // der CI-Bau ohne Schluessel gehen. Wie rosenweg-salz.
    val signierDatei = providers.environmentVariable("SIGNING_STORE_FILE").orNull
    signingConfigs {
        if (signierDatei != null) {
            create("rosenweg") {
                storeFile = file(signierDatei)
                storePassword = providers.environmentVariable("SIGNING_STORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("SIGNING_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("SIGNING_KEY_PASSWORD").get()
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (signierDatei != null) "rosenweg" else "debug")
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
