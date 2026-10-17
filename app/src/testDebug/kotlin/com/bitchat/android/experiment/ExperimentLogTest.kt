package com.bitchat.android.experiment

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.util.concurrent.Executor

/** Each event goes to logcat and is appended to `exp.csv`, which starts with one header (#70). */
class ExperimentLogTest {
    @get:Rule
    val folder = TemporaryFolder()

    private val logcat = mutableListOf<String>()
    private val queued = ArrayDeque<Runnable>()
    private val writer = Executor { queued.addLast(it) }

    private fun runWriter() {
        while (queued.isNotEmpty()) queued.removeFirst().run()
    }

    private fun event(t: Long) = ExperimentEvent(tMs = t, ev = ExperimentEvent.Kind.LINK_DOWN, peer = "88990011")

    @Test
    fun `writing an event only queues work for the background writer`() {
        val file = File(folder.root, "exp.csv")
        val log = ExperimentLog(file, writer) { logcat += it }

        log.write(event(1))

        assertEquals(emptyList<String>(), logcat)
        assertEquals(false, file.exists())
        runWriter()
        assertEquals(listOf("1,LINK_DOWN,,,,,,88990011,,,,,,,"), logcat)
    }

    @Test
    fun `a new file gets the header, then rows in the order they were written`() {
        val file = File(folder.root, "exp.csv")
        val log = ExperimentLog(file, writer) { logcat += it }

        log.write(event(1))
        log.write(event(2))
        runWriter()

        assertEquals(
            listOf(ExperimentEvent.CSV_HEADER, "1,LINK_DOWN,,,,,,88990011,,,,,,,", "2,LINK_DOWN,,,,,,88990011,,,,,,,"),
            file.readLines()
        )
    }

    @Test
    fun `an existing file is appended to without a second header`() {
        val file = File(folder.root, "exp.csv")
        ExperimentLog(file, writer) { }.write(event(1))
        runWriter()

        ExperimentLog(file, writer) { }.write(event(2))
        runWriter()

        assertEquals(
            listOf(ExperimentEvent.CSV_HEADER, "1,LINK_DOWN,,,,,,88990011,,,,,,,", "2,LINK_DOWN,,,,,,88990011,,,,,,,"),
            file.readLines()
        )
    }
}
