// Huawei AppGallery Connect (华为应用市场) — project-level setup.
// The AGC gradle plugin is published as `com.huawei.agconnect:agcp` and has NO
// Gradle plugin-marker artifact, so the `plugins { id("com.huawei.agconnect") }`
// DSL cannot resolve it. It must be loaded via a `buildscript` classpath and
// applied with `apply(plugin = ...)` in the module (see app/build.gradle.kts).
buildscript {
    repositories {
        maven { url = uri("https://developer.huawei.com/repo/") }
        // agcp pulls in common artifacts (e.g. com.google.code.gson:gson) that are
        // NOT hosted on the Huawei repo, so the usual repos must be present too.
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
        google()
        mavenCentral()
    }
    dependencies {
        // AGP must be declared BEFORE agcp: agcp requires com.android.tools.build:gradle
        // to be present, and Gradle resolves the buildscript classpath in declaration
        // order, so listing AGP first keeps AGP 9.1.0's classes ahead of any bundled
        // by agcp (otherwise the module's `android { }` Kotlin DSL fails to compile).
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("com.huawei.agconnect:agcp:1.9.6.300")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://developer.huawei.com/repo/") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
