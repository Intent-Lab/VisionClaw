package com.example.facedetectionapp

import android.app.Application
import com.meta.wearable.dat.core.Wearables

class FaceDetectionApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Wearables.initialize(this)
    }
}
