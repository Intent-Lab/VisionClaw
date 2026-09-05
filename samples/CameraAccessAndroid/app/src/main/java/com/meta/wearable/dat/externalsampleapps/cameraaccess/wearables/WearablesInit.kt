package com.meta.wearable.dat.externalsampleapps.cameraaccess.wearables

import android.content.Context
import com.meta.wearable.dat.core.Wearables

/**
 * Idempotent gate around Wearables.initialize. Phone mode never touches the
 * DAT SDK, so initialization runs lazily on the first glasses-path call
 * instead of unconditionally at startup -- but every glasses entry point must
 * pass through here or Wearables throws "not initialized".
 */
object WearablesInit {
    @Volatile private var initialized = false

    fun ensure(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            Wearables.initialize(context.applicationContext)
            initialized = true
        }
    }
}
