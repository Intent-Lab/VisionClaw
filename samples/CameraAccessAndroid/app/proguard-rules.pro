# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the license found in the
# LICENSE file in the root directory of this source tree.

# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Preserve line numbers for crash reports; rename the source-file
# attribute so it doesn't leak source paths.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# ----- VisionClaw runtime libraries -----
# Without these keep rules the release build (when isMinifyEnabled
# becomes true) will strip classes that GSON/OkHttp/WebRTC reach via
# reflection or native code, causing runtime failures.

# Gson uses reflection to instantiate model classes.
-keepattributes Signature
-keepattributes *Annotation*
-keep class com.google.gson.** { *; }
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class * extends com.google.gson.TypeAdapter
-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

# OkHttp / Okio: optional dependencies referenced by reflection.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
-keep class okhttp3.** { *; }
-keep class okio.** { *; }
-keep interface okhttp3.** { *; }

# WebRTC native bridge: classes are looked up from C++.
-keep class org.webrtc.** { *; }
-keep interface org.webrtc.** { *; }
-dontwarn org.webrtc.**

# CameraX: ProcessCameraProvider and the other entry points are
# resolved reflectively by the androidx initializer.
-keep class androidx.camera.** { *; }
-dontwarn androidx.camera.**

# Kotlin coroutines internals (avoid stripping the suspend machinery).
-keepclassmembernames class kotlinx.coroutines.** {
  volatile <fields>;
}

# Local data classes serialized via JSON / Gson stay intact.
-keep class com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.** { *; }
-keep class com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.** { *; }
