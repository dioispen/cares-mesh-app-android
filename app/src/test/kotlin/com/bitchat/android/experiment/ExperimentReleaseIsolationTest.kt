package com.bitchat.android.experiment

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Release builds carry none of the field-experiment tools (#70): the release `ExperimentTools`
 * hands every mesh insertion point the no-op recorder and registers no bridge method, so no
 * `CARES_EXP` log is written and the Flutter screen has nothing to call.
 *
 * AGP only creates unit-test tasks for the debug build type here (enabling release ones would
 * need new lock state for `app/gradle.lockfile`), so the release source set is checked as source,
 * the way `flutter_ui/test/bridge_contract_test.dart` checks the bridge.
 */
class ExperimentReleaseIsolationTest {
    private val main = File("src/main/java")
    private val debugTools = File("src/debug/java/com/bitchat/android/experiment")
    private val releaseTools = File("src/release/java/com/bitchat/android/experiment/ExperimentTools.kt")

    /** Kotlin source without comments, whitespace collapsed. */
    private fun code(file: File): String = file.readText()
        .replace(Regex("""/\*.*?\*/""", RegexOption.DOT_MATCHES_ALL), " ")
        .replace(Regex("""//[^\n]*"""), " ")
        .replace(Regex("""\s+"""), " ")
        .trim()

    private fun kotlinFiles(dir: File) = dir.walkTopDown().filter { it.isFile && it.extension == "kt" }.toList()

    @Test
    fun `the release ExperimentTools is the no-op recorder and no bridge methods`() {
        val release = code(releaseTools)

        assertTrue(release, release.contains("val recorder: ExperimentRecorder get() = ExperimentRecorder.NoOp"))
        assertTrue(release, release.contains("fun bridgeHandlers(): List<BridgeMethodHandler> = emptyList()"))
        listOf(
            "fun install(context: Context) = Unit",
            "fun onMeshServiceCreated(scope: CoroutineScope) = Unit",
            "fun onMeshServiceDestroyed() = Unit"
        ).forEach { assertTrue(it, release.contains(it)) }
    }

    @Test
    fun `release and debug ExperimentTools offer main the same members`() {
        val members = Regex("""(?:fun|val) (\w+)""")
        fun publicMembers(file: File): Set<String> {
            val source = code(file)
            val body = source.substringAfter("object ExperimentTools {")
            return members.findAll(body)
                .filterNot { body.substring(0, it.range.first).trimEnd().endsWith("private") }
                .map { it.groupValues[1] }
                .toSet()
        }

        val debug = publicMembers(File(debugTools, "ExperimentTools.kt"))
        val release = publicMembers(releaseTools)

        assertTrue(release.containsAll(setOf("recorder", "install", "onMeshServiceCreated", "onMeshServiceDestroyed", "bridgeHandlers")))
        assertTrue("debug has $debug, release has $release", debug.containsAll(release))
    }

    @Test
    fun `main reaches the experiment tools only through ExperimentTools, ExperimentRecorder and ExperimentHandles`() {
        val topLevel = Regex("""^(?:(?:private|internal|data|sealed|enum) )*(?:class|object|interface) (\w+)""", RegexOption.MULTILINE)
        val debugOnly = kotlinFiles(debugTools)
            .flatMap { file -> topLevel.findAll(file.readText()).map { it.groupValues[1] }.toList() }
            .toSet() - "ExperimentTools"
        assertTrue(debugOnly.containsAll(setOf("ExperimentEventRecorder", "ExperimentLog", "ExperimentBridge", "ExperimentSender")))

        val leaks = kotlinFiles(main).flatMap { file ->
            val source = code(file)
            debugOnly.filter { Regex("""\b$it\b""").containsMatchIn(source) }.map { "${file.name}: $it" }
        }

        assertEquals(emptyList<String>(), leaks)
    }

    @Test
    fun `only the debug source set writes the CARES_EXP log`() {
        val writers = (kotlinFiles(main) + releaseTools + kotlinFiles(debugTools))
            .filter { code(it).contains("CARES_EXP") }
            .map { it.invariantSeparatorsPath }

        assertEquals(listOf("src/debug/java/com/bitchat/android/experiment/ExperimentLog.kt"), writers)
    }
}
