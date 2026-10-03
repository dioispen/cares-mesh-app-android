package com.bitchat.android.testsupport

import android.content.Context
import android.content.ContextWrapper
import android.content.res.Resources

/**
 * Unit tests run without the app's merged resources, but classes such as the mesh service and
 * upstream's `ui.NotificationManager` build their notification channels (named from string
 * resources) as they are constructed. This context answers every string (and resource name)
 * lookup with a stand-in; any string will do. It is its own application context, so code that
 * reaches for `applicationContext` keeps the stand-in.
 */
internal class ResourcelessContext(base: Context) : ContextWrapper(base) {
    @Suppress("DEPRECATION")
    private val strings = object : Resources(base.assets, base.resources.displayMetrics, base.resources.configuration) {
        override fun getText(id: Int): CharSequence = "string-$id"
        override fun getString(id: Int): String = "string-$id"
        override fun getString(id: Int, vararg formatArgs: Any?): String = "string-$id"
        override fun getQuantityString(id: Int, quantity: Int, vararg formatArgs: Any?): String = "string-$id"

        // IconCompat.createWithResource (notification shortcuts) looks the icon's name up.
        override fun getResourceName(resid: Int): String = "${base.packageName}:drawable/resource-$resid"
    }

    override fun getApplicationContext(): Context = this
    override fun getResources(): Resources = strings
}
