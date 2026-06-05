package com.meta.wearable.dat.externalsampleapps.cameraaccess.gallery

data class CapturedPhoto(
    val id: String,
    val filename: String,
    val timestamp: Long,
    val description: String?
)
