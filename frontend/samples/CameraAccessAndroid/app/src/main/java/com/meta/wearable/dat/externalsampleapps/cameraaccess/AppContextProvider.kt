package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Context

object AppContextProvider {
    @Volatile
    private var appContext: Context? = null

    fun init(context: Context) {
        appContext = context.applicationContext
    }

    fun require(): Context =
        appContext ?: error("AppContextProvider is not initialized")
}
