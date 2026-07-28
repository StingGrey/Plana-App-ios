import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 发布签名配置(android/key.properties,已在 .gitignore 中排除)。
// 文件不存在时 release 回落 debug 签名,本地开发照常;正式出包必须存在,
// 否则换机/重装 SDK 后签名会变,老用户无法覆盖升级(只能卸载重装丢数据)。
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    namespace = "com.sora214.plana.app"
    compileSdk = 36 // Notification.ProgressStyle(灵动岛/Live Updates)需 API 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.sora214.plana.app"
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

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                // AGP 默认只开 v2(minSdk 24 用不上 v1)。v3 额外带来密钥轮换能力:
                // 万一密钥泄露或需要更换,Android 9+ 能凭轮换链平滑过渡,
                // 而不是让全部老用户卸载重装。低版本自动回落 v2,无兼容风险。
                enableV3Signing = true
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 就用正式签名;没有则回落 debug 签名,
            // 让 `flutter run --release` 在本机仍可用。**对外分发必须用正式签名**。
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // 本地超分 ncnn-vulkan native
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    packaging {
        jniLibs {
            // defaultConfig.abiFilters 管不到插件 AAR 里预编译的 .so:
            // jni/jni_flutter 就把 libdartjni.so 的 v7a/x86_64 版本一起打进来了
            // (181KB 死重,本 app 只出 arm64)。见 audit-findings F0-08。
            excludes += setOf(
                "lib/armeabi-v7a/**",
                "lib/x86/**",
                "lib/x86_64/**",
            )
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
