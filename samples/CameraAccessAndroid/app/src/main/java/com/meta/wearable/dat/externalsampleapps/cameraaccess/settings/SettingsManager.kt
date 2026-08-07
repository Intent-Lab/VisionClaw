package com.meta.wearable.dat.externalsampleapps.cameraaccess.settings

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.meta.wearable.dat.externalsampleapps.cameraaccess.Secrets

object SettingsManager {
    private const val TAG = "SettingsManager"
    private const val PREFS_NAME = "visionclaw_settings"
    private const val SECURE_PREFS_NAME = "visionclaw_secure"

    // Non-sensitive settings (host, port, toggles)
    private lateinit var prefs: SharedPreferences
    // Secrets (API keys, tokens) — encrypted at rest
    private lateinit var securePrefs: SharedPreferences

    fun init(context: Context) {
        prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        securePrefs = EncryptedSharedPreferences.create(
            context,
            SECURE_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

        migrateSecretsFromPlainPrefs()
    }

    /** One-time migration: move secrets from plain SharedPreferences to EncryptedSharedPreferences. */
    private fun migrateSecretsFromPlainPrefs() {
        if (prefs.getBoolean("secrets_migrated", false)) return

        val secretKeys = listOf("geminiAPIKey", "openClawHookToken", "openClawGatewayToken")
        for (key in secretKeys) {
            val value = prefs.getString(key, null)
            if (value != null) {
                securePrefs.edit().putString(key, value).apply()
                prefs.edit().remove(key).apply()
                Log.d(TAG, "Migrated $key to encrypted storage")
            }
        }

        prefs.edit().putBoolean("secrets_migrated", true).apply()
    }

    // Secrets — stored in EncryptedSharedPreferences
    var geminiAPIKey: String
        get() = securePrefs.getString("geminiAPIKey", null) ?: Secrets.geminiAPIKey
        set(value) = securePrefs.edit().putString("geminiAPIKey", value).apply()

    var openClawHookToken: String
        get() = securePrefs.getString("openClawHookToken", null) ?: Secrets.openClawHookToken
        set(value) = securePrefs.edit().putString("openClawHookToken", value).apply()

    var openClawGatewayToken: String
        get() = securePrefs.getString("openClawGatewayToken", null) ?: Secrets.openClawGatewayToken
        set(value) = securePrefs.edit().putString("openClawGatewayToken", value).apply()

    // Non-sensitive settings — plain SharedPreferences
    var geminiSystemPrompt: String
        get() = prefs.getString("geminiSystemPrompt", null) ?: DEFAULT_SYSTEM_PROMPT
        set(value) = prefs.edit().putString("geminiSystemPrompt", value).apply()

    var openClawHost: String
        get() = prefs.getString("openClawHost", null) ?: Secrets.openClawHost
        set(value) = prefs.edit().putString("openClawHost", value).apply()

    var openClawPort: Int
        get() {
            val stored = prefs.getInt("openClawPort", 0)
            return if (stored != 0) stored else Secrets.openClawPort
        }
        set(value) = prefs.edit().putInt("openClawPort", value).apply()

    var webrtcSignalingURL: String
        get() = prefs.getString("webrtcSignalingURL", null) ?: Secrets.webrtcSignalingURL
        set(value) = prefs.edit().putString("webrtcSignalingURL", value).apply()

    var videoStreamingEnabled: Boolean
        get() = prefs.getBoolean("videoStreamingEnabled", true)
        set(value) = prefs.edit().putBoolean("videoStreamingEnabled", value).apply()

    var proactiveNotificationsEnabled: Boolean
        get() = prefs.getBoolean("proactiveNotificationsEnabled", true)
        set(value) = prefs.edit().putBoolean("proactiveNotificationsEnabled", value).apply()

    fun resetAll() {
        securePrefs.edit().clear().apply()
        prefs.edit().clear().apply()
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
