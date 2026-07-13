plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.plana.plana_app"
    compileSdk = 36 // Notification.ProgressStyle(灵动岛/Live Updates)需 API 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.plana.plana_app"
        minSdk = 24 // Vulkan compute(本地超分 ncnn-vulkan)需 API 24+
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters += "arm64-v8a" // 本地超分 native 只出 arm64(覆盖现代机型)
        }
        externalNativeBuild {
            cmake {
                arguments += "-DANDROID_STL=c++_shared"
                cppFlags += "-std=c++17"
                abiFilters += "arm64-v8a" // native 只编 arm64(只备了这个 ABI 的 ncnn 库)
            }
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // 本地超分 ncnn-vulkan native
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
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
    // NotificationCompat.ProgressStyle + setRequestPromotedOngoing:
    // 跨版本请求把进度通知提升上岛(状态栏胶囊/锁屏);低版本自动 no-op。
    // 框架 Notification.Builder 在 android-36(stable)尚无 requestPromotedOngoing,故走 compat。
    implementation("androidx.core:core:1.18.0")
}
