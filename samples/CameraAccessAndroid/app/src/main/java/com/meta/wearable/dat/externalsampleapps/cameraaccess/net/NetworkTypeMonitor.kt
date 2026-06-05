// app/src/main/java/com/meta/wearable/dat/externalsampleapps/cameraaccess/net/NetworkTypeMonitor.kt
package com.meta.wearable.dat.externalsampleapps.cameraaccess.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

enum class NetworkType {
    WIFI,
    CELLULAR,
    OTHER,
    NONE
}

class NetworkTypeMonitor(context: Context) {
    companion object {
        private const val TAG = "NetworkTypeMonitor"
    }

    private val cm = context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private val _networkType = MutableStateFlow(NetworkType.NONE)
    val networkType: StateFlow<NetworkType> = _networkType.asStateFlow()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            update()
        }

        override fun onLost(network: Network) {
            update()
        }

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
            update()
        }
    }

    fun start() {
        try {
            cm.registerDefaultNetworkCallback(callback)
        } catch (e: Exception) {
            Log.e(TAG, "registerDefaultNetworkCallback failed: ${e.message}")
        }
        update()
    }

    fun stop() {
        try {
            cm.unregisterNetworkCallback(callback)
        } catch (_: Exception) {
        }
    }

    private fun update() {
        val active = cm.activeNetwork
        if (active == null) {
            _networkType.value = NetworkType.NONE
            return
        }
        val caps = cm.getNetworkCapabilities(active)
        if (caps == null) {
            _networkType.value = NetworkType.OTHER
            return
        }

        _networkType.value = when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> NetworkType.WIFI
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> NetworkType.CELLULAR
            else -> NetworkType.OTHER
        }
    }
}