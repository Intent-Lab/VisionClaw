package com.meta.wearable.dat.externalsampleapps.cameraaccess

import android.content.Intent
import android.service.quicksettings.TileService

class QuickStartTileService : TileService() {
  override fun onClick() {
    super.onClick()

    val intent = Intent(this, MainActivity::class.java).apply {
      action = MainActivity.ACTION_QUICK_START_STREAMING
      addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    // API 34+ supports intent directly; fallback to startActivity on older versions
    try {
      @Suppress("DEPRECATION")
      startActivityAndCollapse(intent)
    } catch (_: Throwable) {
      intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
      startActivity(intent)
      @Suppress("DEPRECATION")
      try {
        startActivityAndCollapse(Intent())
      } catch (_: Throwable) {
      }
    }
  }
}
