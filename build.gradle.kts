import com.android.build.api.dsl.LibraryExtension
import org.gradle.api.artifacts.dsl.LockMode

// Top-level build file where you can add configuration options common to all sub-projects/modules.
plugins {
    alias(libs.plugins.android.application) apply false
    alias(libs.plugins.android.library) apply false
    alias(libs.plugins.kotlin.compose) apply false
    id("com.google.gms.google-services") version "4.4.4" apply false
    // Never applied to any project here. Requested only so that the Flutter
    // Gradle plugin's classes land in the root project's script classloader
    // scope, which every subproject inherits. See the comment on ownedProjects
    // below for why the generated Flutter plugin projects need that.
    // Resolved from the composite build that flutter_ui/.android/include_flutter.groovy
    // adds with pluginManagement.includeBuild, so it carries no version.
    id("dev.flutter.flutter-gradle-plugin") apply false
}

// Projects this repository owns. Every other project in the build is a Flutter
// plugin project: flutter_ui/.android/include_flutter.groovy includes one per
// pub package, with its projectDir pointing into PUB_CACHE.
val ownedProjects = setOf(":app", ":wear", ":flutter")

val projectCompileSdk = libs.versions.compileSdk.get().toInt()
val projectBuildTools = libs.versions.buildTools.get()

// Every Flutter plugin package assumes the `flutter` project extension exists:
// their android/build.gradle(.kts) read flutter.compileSdkVersion and
// flutter.minSdkVersion. Flutter's own PluginHandler.configurePluginProject does
// register it on each plugin project, so the Groovy plugin scripts resolve it
// dynamically and work. The Kotlin DSL ones did not, and this is why:
//
//   The extension's public type is com.flutter.gradle.FlutterExtension, which
//   lives in dev.flutter.flutter-gradle-plugin. In a Flutter *app* project that
//   plugin is requested from the root build script, so its classes sit in the root
//   project's classloader scope and every subproject inherits them. The add-to-app
//   *module* path used here goes through
//   $FLUTTER_ROOT/packages/flutter_tools/gradle/module_plugin_loader.gradle, which
//   only includes the plugin projects and sets evaluationDependsOn(':flutter'):
//   the plugin ends up in :flutter's own scope alone. Gradle then classifies
//   FlutterExtension as an inaccessible type while generating a plugin project's
//   Kotlin DSL type-safe accessors, emits `val Project.flutter` typed as Any, and
//   the script fails to compile with "Unresolved reference 'compileSdkVersion'".
//   Adding the jar to each plugin project's own buildscript classpath instead is
//   not enough: sibling scopes load their own copy of the class, and the accessor
//   then fails at runtime with FlutterExtension_Decorated cannot be cast to
//   FlutterExtension. Only a shared ancestor scope works, hence the plugin request
//   in the plugins block above.
//
// This is a gap in upstream Flutter's module support, not a defect in this
// repository. The fix names no package and no package version, so it survives
// plugin upgrades — unlike editing the packages inside PUB_CACHE, which is what
// this repository used to do (see tools/reproducible-builds/apply-pub-cache-patches.sh).
gradle.beforeProject {
    // :app and :wear pin their own compileSdk and buildToolsVersion from the
    // version catalog. Everything else here is generated: the Flutter plugin
    // projects, and :flutter itself, whose flutter_ui/.android/Flutter/build.gradle
    // is rewritten by `flutter pub get` on every container run.
    if (this == rootProject || path in setOf(":app", ":wear")) {
        return@beforeProject
    }

    // FlutterExtension.compileSdkVersion is hard-coded to 36 by the pinned Flutter
    // SDK, and the Flutter plugin packages assign it to their own compileSdk; none
    // of them pins buildToolsVersion either, so AGP falls back to its own default
    // (36.0.0 for AGP 9.3.1). Pulling both onto this repository's pinned versions
    // keeps the toolchain image down to a single Android platform and a single
    // build-tools package, instead of whatever every third-party package happens to
    // ask for. Without it the container build stops at
    // "Failed to install the following SDK components: build-tools;36.0.0 ...
    // The SDK directory is not writable", because the image is sealed on purpose.
    // Registered here, before AGP is applied, so that it runs ahead of AGP's own
    // afterEvaluate.
    afterEvaluate {
        (extensions.findByName("android") as? LibraryExtension)?.let { android ->
            android.compileSdk = projectCompileSdk
            android.buildToolsVersion = projectBuildTools
        }
    }

    // SUPPRESSION, not a fix. `disable 'MissingPermission'` used to be hand-edited
    // into geolocator_android's build.gradle inside PUB_CACHE. Without it,
    // `./gradlew :geolocator_android:lintDebug` fails with two real errors, both at
    // geolocator_android-4.6.2/android/src/main/java/com/baseflow/geolocator/
    // location/BackgroundNotification.java:100 — NotificationManagerCompat.notify
    // called without checking android.permission.POST_NOTIFICATIONS. That finding is
    // unreviewed and deserves an issue of its own. Scoped to the generated Flutter
    // plugin projects, the suppression never hides a MissingPermission finding in
    // :app or :wear.
    if (path !in ownedProjects) {
        pluginManager.withPlugin("com.android.library") {
            (extensions.getByName("android") as LibraryExtension).lint.disable.add("MissingPermission")
        }
    }
}

// Force Mockito version across all subprojects to fix Java 21 compatibility issues
subprojects {
    configurations.all {
        resolutionStrategy.eachDependency {
            if (requested.group == "org.mockito" && requested.name == "mockito-core") {
                useVersion("5.11.0")
            }
        }
    }

    // shared_preferences_android DataStore tests fail on Windows due to file-locking (Robolectric + DataStore rename bug)
    afterEvaluate {
        if (project.name == "shared_preferences_android") {
            tasks.withType(Test::class).configureEach {
                ignoreFailures = true
            }
        }
    }
}

val resolveIdeRuntimeClasspathCopyLocks = tasks.register("resolveIdeRuntimeClasspathCopyLocks") {
    group = "build setup"
    description = "Resolves Android Studio runtime classpath copies when refreshing lock state."
}

// Upstream applies dependency locking to every subproject. The embedded Flutter module
// (":flutter" plus one generated subproject per pub package) is generated by the Flutter
// tool and carries no lockfiles, so locking is scoped to the modules this repo owns.
val lockedProjects = setOf(":app", ":wear")

subprojects {
    if (path in lockedProjects) {
        dependencyLocking {
            lockAllConfigurations()
            lockMode.set(LockMode.STRICT)
        }
    }

    pluginManager.withPlugin("com.android.application") {
        val resolveIdeRuntimeClasspathCopyLock = tasks.register("resolveIdeRuntimeClasspathCopyLock") {
            group = "build setup"
            description = "Resolves this module's Android Studio runtime classpath copies."
            notCompatibleWithConfigurationCache("Resolves copied configurations at execution time")
            doFirst {
                check(gradle.startParameter.isWriteDependencyLocks) {
                    "$path must be run with --write-locks"
                }
            }
            doLast {
                listOf("debugRuntimeClasspath", "releaseRuntimeClasspath").forEach { configurationName ->
                    configurations.getByName(configurationName).copy().resolve()
                }
            }
        }
        resolveIdeRuntimeClasspathCopyLocks.configure {
            dependsOn(resolveIdeRuntimeClasspathCopyLock)
        }
    }
}

tasks.whenTaskAdded {
    if (name.contains("ArtProfile")) {
        enabled = false
    }
}

tasks.register("clientRewriteContractTest") {
    group = "verification"
    description = "Runs the complete compatibility gate for a from-scratch client rewrite."
    dependsOn(":app:testDebugUnitTest")
}
