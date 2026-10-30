import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.retroemupouch.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
    }

    // Pinned emulator-core commits, surfaced at runtime (bench JSON + about page).
    val corePinLines: List<String> = file("../../../third_party/CORE_PINS.txt")
        .takeIf { it.exists() }
        ?.readLines()
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() && !it.startsWith("#") }
        ?: emptyList()
    val coreCommit: String = corePinLines
        .firstOrNull { it.startsWith("fceumm ") }
        ?.substringAfter(" ")
        ?: "dev"
    // Semicolon-delimited "<id> <sha>" records consumed per-core via GS_CORE_PINS.
    val corePins: String = corePinLines.joinToString(";")

    // ------------------------------------------------------------------
    // Channel flavours (compliance remediation P0-1b).
    //
    //   store     - 华为/小米/Google Play 渠道：禁止自更新、不下发 ROM、
    //               全局禁止明文流量。上架必须构建此变体。
    //   community - 自签 sideload / 局域网自建服务：保留完整能力
    //               （REQUEST_INSTALL_PACKAGES + OTA 自装 + 明文局域网）。
    //
    // Flavour 名与 Dart 侧 `--dart-define=CHANNEL=<name>` 必须一致，
    // 见 app/lib/config/app_channel.dart。
    // ------------------------------------------------------------------
    flavorDimensions += "channel"
    productFlavors {
        create("store") {
            dimension = "channel"
        }
        create("community") {
            dimension = "channel"
        }
    }

    // ------------------------------------------------------------------
    // Release signing (compliance remediation P0-3).
    //
    // 绝不能再用 debug keystore：debug 签名无法接入 Play App Signing /
    // 华为签名服务，密钥泄露即失控，且用户无法安全升级。
    // 密钥来自 gitignore 的 keystore.properties（本地）或 CI 环境变量，
    // 二者都没有时直接让构建失败，而不是静默回退 debug。
    // ------------------------------------------------------------------
    val keystoreProps = run {
        val f = file("../../../keystore.properties")
        if (!f.exists()) return@run null
        val p = Properties()
        f.inputStream().use { p.load(it) }
        p
    }
    fun ks(key: String, env: String): String? {
        val fromProps = keystoreProps?.getProperty(key)
        if (!fromProps.isNullOrBlank()) return fromProps
        return System.getenv(env)
    }

    signingConfigs {
        create("release") {
            val storeFilePath = ks("storeFile", "GP_KS_FILE")
            storeFile = storeFilePath?.let { file(it) }
            storePassword = ks("storePassword", "GP_KS_PWD")
            keyAlias = ks("keyAlias", "GP_KEY_ALIAS")
            keyPassword = ks("keyPassword", "GP_KEY_PWD")
        }
    }

    defaultConfig {
        applicationId = "com.retroemupouch.app"
        // AAudio (low-latency audio) requires API 26 (Android 8.0);
        // the HarmonyOS 4.2 AOSP compat layer is API 31.
        minSdk = maxOf(26, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        buildConfigField("String", "GS_CORE_COMMIT", "\"$coreCommit\"")
        buildConfigField("String", "GS_CORE_PINS", "\"$corePins\"")

        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_static")
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    buildTypes {
        release {
            // P0-3: dedicated release keystore. Never fall back to debug —
            // a debug-signed release cannot be enrolled in Play App Signing
            // and cannot be upgraded safely once the key leaks.
            val cfg = signingConfigs.getByName("release")
            if (cfg.storeFile == null || cfg.keyAlias == null) {
                throw GradleException(
                    "未配置 release 签名：请在项目根目录提供 keystore.properties " +
                        "(参考 keystore.properties.template)，或设置 GP_KS_FILE/GP_KS_PWD/" +
                        "GP_KEY_ALIAS/GP_KEY_PWD 环境变量。" +
                        "本地生成可执行 scripts\\make-release-keystore.ps1"
                )
            }
            signingConfig = cfg
            // 代码压缩/资源收缩需要一套验证过的 ProGuard/R8 规则（JNI +
            // libretro 内核反射较多），确认规则后再开启，避免运行时崩溃：
            // isMinifyEnabled = true
            // isShrinkResources = true
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
    // AppGallery Connect SDK 基础包 (华为应用市场).
    implementation("com.huawei.agconnect:agconnect-core:1.9.6.300")
}

// Huawei requirement: the AGC plugin must be applied at the BOTTOM of the
// module file. It processes agconnect-services.json (kept at this module root);
// that file's `package_name` must equal applicationId (com.retroemupouch.app).
apply(plugin = "com.huawei.agconnect")
