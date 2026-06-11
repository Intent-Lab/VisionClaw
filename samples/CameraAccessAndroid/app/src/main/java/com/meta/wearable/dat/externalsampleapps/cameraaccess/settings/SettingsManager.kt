package com.meta.wearable.dat.externalsampleapps.cameraaccess.settings

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.meta.wearable.dat.externalsampleapps.cameraaccess.BuildConfig
import com.meta.wearable.dat.externalsampleapps.cameraaccess.Secrets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object SettingsManager {
    private const val PREFS_NAME = "visionclaw_settings"
    private const val SECURE_PREFS_NAME = "visionclaw_secure_settings"
    private const val SECURE_KEY_ALIAS = "visionclaw.secure.settings"

    private lateinit var prefs: SharedPreferences
    private lateinit var secureStore: AndroidSecureStringStore

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        secureStore = AndroidSecureStringStore(
            context.getSharedPreferences(SECURE_PREFS_NAME, Context.MODE_PRIVATE),
            SECURE_KEY_ALIAS
        )
    }

    var geminiAPIKey: String
        get() {
            val stored = getSecureString("geminiAPIKey")
            if (!stored.isNullOrBlank()) return stored

            return Secrets.geminiAPIKey
        }
        set(value) = putSecureString("geminiAPIKey", value)

    var geminiSystemPrompt: String
        get() = prefs.getString("geminiSystemPrompt", null) ?: DEFAULT_SYSTEM_PROMPT
        set(value) = prefs.edit().putString("geminiSystemPrompt", value).apply()

    var workerLoginCode: String
        get() = prefs.getString("workerLoginCode", null) ?: Secrets.workerLoginCode
        set(value) = prefs.edit().putString("workerLoginCode", value).apply()

    var opsBaseURL: String
        get() = prefs.getString("opsBaseURL", null) ?: Secrets.opsBaseURL
        set(value) = prefs.edit().putString("opsBaseURL", value).apply()

    var signalBaseURL: String
        get() {
            val stored = prefs.getString("signalBaseURL", null)
            if (!stored.isNullOrBlank()) return stored

            val legacy = prefs.getString("webrtcSignalingURL", null)
            if (!legacy.isNullOrBlank()) return normalizeSignalBaseURL(legacy)

            return Secrets.signalBaseURL
        }
        set(value) = prefs.edit().putString("signalBaseURL", normalizeSignalBaseURL(value)).apply()

    var openClawHost: String
        get() = prefs.getString("openClawHost", null) ?: Secrets.openClawHost
        set(value) = prefs.edit().putString("openClawHost", value).apply()

    var openClawPort: Int
        get() {
            val stored = prefs.getInt("openClawPort", 0)
            return if (stored != 0) stored else Secrets.openClawPort
        }
        set(value) = prefs.edit().putInt("openClawPort", value).apply()

    var openClawHookToken: String
        get() = getSecureString("openClawHookToken") ?: Secrets.openClawHookToken
        set(value) = putSecureString("openClawHookToken", value)

    var openClawGatewayToken: String
        get() = getSecureString("openClawGatewayToken") ?: Secrets.openClawGatewayToken
        set(value) = putSecureString("openClawGatewayToken", value)

    var webrtcSignalingURL: String
        get() = normalizeWebsocketURL(signalBaseURL)
        set(value) {
            val normalized = normalizeSignalBaseURL(value)
            prefs.edit()
                .putString("signalBaseURL", normalized)
                .putString("webrtcSignalingURL", normalized)
                .apply()
        }

    var openClawTailscaleIP: String
        get() {
            val stored = prefs.getString("openClawTailscaleIP", null)
            if (!stored.isNullOrBlank()) return stored

            val buildValue = BuildConfig.OPENCLAW_TAILSCALE_IP
            if (buildValue.isNotBlank()) return buildValue

            return Secrets.openClawTailscaleIP
        }
        set(value) = prefs.edit().putString("openClawTailscaleIP", value).apply()

    var openClawBearerToken: String
        get() {
            val stored = getSecureString("openClawBearerToken")
            if (!stored.isNullOrBlank()) return stored

            return Secrets.openClawBearerToken
        }
        set(value) = putSecureString("openClawBearerToken", value)

    var deviceId: String
        get() {
            val stored = prefs.getString("deviceId", null)
            if (!stored.isNullOrBlank()) return stored

            val secret = Secrets.deviceId
            if (secret.isNotBlank() && secret != "YOUR_DEVICE_UUID") {
                prefs.edit().putString("deviceId", secret).apply()
                return secret
            }

            val generated = UUID.randomUUID().toString()
            prefs.edit().putString("deviceId", generated).apply()
            return generated
        }
        set(value) = prefs.edit().putString("deviceId", value).apply()

    var videoStreamingEnabled: Boolean
        get() = prefs.getBoolean("videoStreamingEnabled", true)
        set(value) = prefs.edit().putBoolean("videoStreamingEnabled", value).apply()

    var proactiveNotificationsEnabled: Boolean
        get() = prefs.getBoolean("proactiveNotificationsEnabled", true)
        set(value) = prefs.edit().putBoolean("proactiveNotificationsEnabled", value).apply()

    fun resetAll() {
        prefs.edit().clear().apply()
        secureStore.clear()
    }

    private fun normalizeSignalBaseURL(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return trimmed
        return when {
            trimmed.startsWith("wss://") -> "https://${trimmed.removePrefix("wss://")}"
            trimmed.startsWith("ws://") -> "http://${trimmed.removePrefix("ws://")}"
            trimmed.startsWith("https://") || trimmed.startsWith("http://") -> trimmed
            else -> "https://$trimmed"
        }
    }

    private fun normalizeWebsocketURL(raw: String): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return trimmed
        return when {
            trimmed.startsWith("wss://") || trimmed.startsWith("ws://") -> trimmed
            trimmed.startsWith("https://") -> "wss://${trimmed.removePrefix("https://")}"
            trimmed.startsWith("http://") -> "ws://${trimmed.removePrefix("http://")}"
            else -> "wss://$trimmed"
        }
    }

    private fun getSecureString(key: String): String? {
        val stored = secureStore.getString(key)
        if (!stored.isNullOrBlank()) return stored

        val legacy = prefs.getString(key, null)
        if (!legacy.isNullOrBlank()) {
            secureStore.putString(key, legacy)
            prefs.edit().remove(key).apply()
            return legacy
        }

        return null
    }

    private fun putSecureString(key: String, value: String) {
        val trimmed = value.trim()
        prefs.edit().remove(key).apply()

        if (trimmed.isEmpty()) {
            secureStore.remove(key)
        } else {
            secureStore.putString(key, trimmed)
        }
    }

    const val DEFAULT_SYSTEM_PROMPT = """You are an AI assistant for someone wearing Meta Ray-Ban smart glasses. You can see through their camera and have a voice conversation. Keep responses concise and natural.

CRITICAL: You have NO memory, NO storage, and NO ability to take actions on your own. You cannot remember things, keep lists, set reminders, search the web, send messages, or do anything persistent. You are ONLY a voice interface.

You have exactly ONE tool: execute. This connects you to a powerful personal assistant that can do anything -- send messages, search the web, manage lists, set reminders, create notes, research topics, control smart home devices, interact with apps, and much more.

ALWAYS use execute when the user asks you to:
- Send a message to someone (any platform: WhatsApp, Telegram, iMessage, Slack, etc.)
- Search or look up anything (web, local info, facts, news)
- Add, create, or modify anything (shopping lists, reminders, notes, todos, events)
- Research, analyze, or draft anything
- Control or interact with apps, devices, or services
- Remember or store any information for later

Be detailed in your task description. Include all relevant context: names, content, platforms, quantities, etc. The assistant works better with complete information.

NEVER pretend to do these things yourself.

IMPORTANT: Before calling execute, ALWAYS speak a brief acknowledgment first. For example:
- "Sure, let me add that to your shopping list." then call execute.
- "Got it, searching for that now." then call execute.
- "On it, sending that message." then call execute.
Never call execute silently -- the user needs verbal confirmation that you heard them and are working on it. The tool may take several seconds to complete, so the acknowledgment lets them know something is happening.

For messages, confirm recipient and content before delegating unless clearly urgent."""
}

private class AndroidSecureStringStore(
    private val prefs: SharedPreferences,
    private val keyAlias: String,
) {
    fun getString(key: String): String? {
        val encoded = prefs.getString(key, null) ?: return null
        return runCatching { decrypt(encoded) }.getOrNull()
    }

    fun putString(key: String, value: String) {
        prefs.edit().putString(key, encrypt(value)).apply()
    }

    fun remove(key: String) {
        prefs.edit().remove(key).apply()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    private fun encrypt(value: String): String {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateSecretKey())
        val encrypted = cipher.doFinal(value.toByteArray(Charsets.UTF_8))
        val iv = cipher.iv
        return "${encode(iv)}:${encode(encrypted)}"
    }

    private fun decrypt(value: String): String {
        val parts = value.split(":", limit = 2)
        require(parts.size == 2) { "Invalid secure value format" }

        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            getOrCreateSecretKey(),
            GCMParameterSpec(TAG_LENGTH_BITS, decode(parts[0]))
        )
        return String(cipher.doFinal(decode(parts[1])), Charsets.UTF_8)
    }

    private fun getOrCreateSecretKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existingKey = keyStore.getKey(keyAlias, null) as? SecretKey
        if (existingKey != null) return existingKey

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE)
        val spec = KeyGenParameterSpec.Builder(
            keyAlias,
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .build()
        keyGenerator.init(spec)
        return keyGenerator.generateKey()
    }

    private fun encode(value: ByteArray): String =
        Base64.encodeToString(value, Base64.NO_WRAP)

    private fun decode(value: String): ByteArray =
        Base64.decode(value, Base64.NO_WRAP)

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val TAG_LENGTH_BITS = 128
    }
}
