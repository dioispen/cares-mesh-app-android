pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    // PREFER_SETTINGS (not upstream's FAIL_ON_PROJECT_REPOS): the Flutter module's
    // include_flutter.groovy declares its own project-level repositories.
    repositoriesMode.set(RepositoriesMode.PREFER_SETTINGS)
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
        maven { url = uri("https://storage.googleapis.com/download.flutter.io") }
    }
}

rootProject.name = "bitchat-android"
include(":app")
// :wear (upstream's Wear OS app) is not built by this fork (#38). It shares
// applicationId com.bitchat.droid with :app but has a far higher versionCode, so an
// unqualified installDebug overwrote the phone app with the watch APK. The wear/
// directory stays in the tree so upstream merges don't hit delete/modify conflicts.
// include(":wear")
// Using published Arti AAR; local module not included

val flutterProjectDir = settingsDir.resolve("flutter_ui")

// 2. 執行 Flutter 專案中的配置腳本
apply(from = File(flutterProjectDir, ".android/include_flutter.groovy"))
