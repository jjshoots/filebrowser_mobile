pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP held at 8.13.x (not 9.x): AGP 9 enforces "Built-in Kotlin", which
    // still breaks plugins that apply the Kotlin Gradle Plugin themselves
    // (share_plus, flutter_secure_storage; see plus_plugins#3745 and
    // flutter/flutter#187042). share_plus 12 requires AGP >= 8.12.1.
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.4.10" apply false
}

include(":app")
