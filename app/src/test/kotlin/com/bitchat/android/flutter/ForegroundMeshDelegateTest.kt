package com.bitchat.android.flutter

import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.bitchat.android.mesh.MeshDelegate
import com.bitchat.android.mesh.MeshService
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import org.mockito.kotlin.anyOrNull
import org.mockito.kotlin.doAnswer
import org.mockito.kotlin.mock
import org.mockito.kotlin.whenever

/**
 * Fixes the Flutter entry's foreground rule (#50, #56): the chat core is the mesh delegate exactly
 * while the Activity is resumed, as MainActivity's onResume/onPause make it. Upstream's read
 * receipts, notification choice and outbox flush on peer updates all hang on that attachment.
 */
class ForegroundMeshDelegateTest {

    /** Every value assigned to the mesh delegate, in order. */
    private val assigned = mutableListOf<MeshDelegate?>()
    private val mesh = mock<MeshService>().also { mesh ->
        whenever(mesh.delegate).thenAnswer { assigned.lastOrNull() }
        doAnswer { assigned += it.arguments[0] as MeshDelegate?; null }.whenever(mesh).delegate = anyOrNull()
    }
    private val chatCore = mock<MeshDelegate>()
    private val foreground = ForegroundMeshDelegate(mesh) { chatCore }
    private val owner = TestOwner().also { it.lifecycle.addObserver(foreground) }

    @Test
    fun `nothing is attached before the entry is resumed`() {
        owner.move(Lifecycle.Event.ON_CREATE, Lifecycle.Event.ON_START)

        assertEquals(emptyList<MeshDelegate?>(), assigned)
    }

    @Test
    fun `resuming attaches the chat core`() {
        owner.move(Lifecycle.Event.ON_CREATE, Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME)

        assertSame(chatCore, mesh.delegate)
    }

    @Test
    fun `pausing detaches it, so the app counts as in the background`() {
        // Also what a private chat screen left open behind the home screen gets: no delegate, so
        // upstream sends no read receipts and BluetoothMeshService posts the notifications itself.
        owner.move(Lifecycle.Event.ON_CREATE, Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME)

        owner.move(Lifecycle.Event.ON_PAUSE)
        assertNull(mesh.delegate)

        owner.move(Lifecycle.Event.ON_STOP)
        assertNull(mesh.delegate)
    }

    @Test
    fun `coming back to the front attaches it again`() {
        owner.move(Lifecycle.Event.ON_CREATE, Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME)
        owner.move(Lifecycle.Event.ON_PAUSE, Lifecycle.Event.ON_STOP)

        owner.move(Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME)

        assertEquals(listOf(chatCore, null, chatCore), assigned)
    }

    @Test
    fun `a transport that starts while in front is attached too, but not while in the background`() {
        // Wi-Fi Aware coming up after the UI: re-assigning makes the unified service wire it up.
        owner.move(Lifecycle.Event.ON_CREATE, Lifecycle.Event.ON_START, Lifecycle.Event.ON_RESUME)
        foreground.reattach()
        assertEquals(listOf(chatCore, chatCore), assigned)

        owner.move(Lifecycle.Event.ON_PAUSE)
        foreground.reattach()

        assertEquals(listOf(chatCore, chatCore, null), assigned)
    }

    private class TestOwner : LifecycleOwner {
        private val registry = LifecycleRegistry.createUnsafe(this)
        override val lifecycle: Lifecycle get() = registry

        fun move(vararg events: Lifecycle.Event) = events.forEach(registry::handleLifecycleEvent)
    }
}
