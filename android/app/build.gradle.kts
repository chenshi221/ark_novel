plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.chenshi221.ark_novel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    androidResources {
        noCompress += "tflite"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.chenshi221.ark_novel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 正式签名：android/key.properties（已在 android/.gitignore 里，不入库）写 storeFile（相对 android/ 目录）、storePassword、keyAlias、keyPassword 四项。
    // 没有这个文件就照旧用 debug 签名，和以前装在手机上的包一致。
    // 注意：换签名后不能覆盖安装，要先卸载（会清空 App 数据），已经装着 debug 签名包的手机不要随便加这个文件。
    val releaseKeys = java.util.Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }

    signingConfigs {
        getByName("debug") {
            val customKeystore = file("${System.getProperty("user.home")}/.android/hikari-debug.keystore")
            if (customKeystore.exists()) {
                storeFile = customKeystore
            }
        }
        if (!releaseKeys.isEmpty()) {
            create("release") {
                storeFile = rootProject.file(releaseKeys.getProperty("storeFile"))
                storePassword = releaseKeys.getProperty("storePassword")
                keyAlias = releaseKeys.getProperty("keyAlias")
                keyPassword = releaseKeys.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseKeys.isEmpty()) "debug" else "release")
        }
    }
}

// release 包只给 arm64 手机：--target-platform 只管 Flutter 自己的 .so，
// Cronet、sqlite3 等插件还会带 x86_64 / armeabi-v7a 各一份（约 14 MB）。debug 不受影响，模拟器照常能跑。
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(listOf("lib/x86_64/**", "lib/armeabi-v7a/**", "lib/x86/**"))
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
    // 封面超分辨率的推理库（原 TensorFlow Lite），见 Upscaler.kt
    implementation("com.google.ai.edge.litert:litert:1.4.2")
}
