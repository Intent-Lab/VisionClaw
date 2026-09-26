package com.meta.wearable.dat.externalsampleapps.cameraaccess.livekit

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import com.meta.wearable.dat.externalsampleapps.cameraaccess.settings.SettingsManager
import kotlin.math.PI
import kotlin.math.min
import kotlin.math.sin

/**
 * Short audio cues for call-state changes, played in assistive mode.
 *
 * Blind users cannot see the call screen, and TalkBack announcements only
 * reach people who run TalkBack -- often not the case for older users, who are
 * exactly who assistive mode is for. A cue in the ear is the one signal that
 * always lands, so the user never talks into a dead call without knowing.
 *
 * Tones are synthesized in memory rather than shipped as sound files. The note
 * sequences match iOS (OpenClaw/Earcons.swift); keep the two in step so a cue
 * means the same thing on both platforms.
 */
object Earcons {
    enum class Cue(val notes: List<Pair<Double, Double>>) {
        // (frequency Hz, duration s); a frequency of 0 is a rest.
        CONNECTED(listOf(660.0 to 0.09, 0.0 to 0.03, 990.0 to 0.12)),
        ENDED(listOf(990.0 to 0.09, 0.0 to 0.03, 660.0 to 0.12)),
        LOST(listOf(520.0 to 0.15, 0.0 to 0.06, 390.0 to 0.25)),
        RECONNECTED(listOf(660.0 to 0.07, 0.0 to 0.02, 830.0 to 0.07, 0.0 to 0.02, 990.0 to 0.1)),
        CAPTURED(listOf(1800.0 to 0.04)),
    }

    private const val SAMPLE_RATE = 44_100
    private val cache = mutableMapOf<Cue, ShortArray>()

    /** Plays [cue] if assistive mode is on. Safe to call from any state change. */
    fun play(cue: Cue) {
        if (!SettingsManager.assistiveMode) return
        val samples = cache.getOrPut(cue) { synthesize(cue.notes) }
        // Sonification, not media: it plays alongside the call without taking
        // audio focus from the agent's voice.
        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build(),
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
            )
            .setTransferMode(AudioTrack.MODE_STATIC)
            .setBufferSizeInBytes(samples.size * 2)
            .build()
        track.write(samples, 0, samples.size)
        track.setVolume(0.8f)
        track.notificationMarkerPosition = samples.size
        track.setPlaybackPositionUpdateListener(
            object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(t: AudioTrack) = t.release()
                override fun onPeriodicNotification(t: AudioTrack) {}
            },
        )
        track.play()
    }

    /**
     * 16-bit mono PCM. Each note gets a short fade in and out so it starts and
     * stops without a click.
     */
    private fun synthesize(notes: List<Pair<Double, Double>>): ShortArray {
        val fade = (SAMPLE_RATE * 0.008).toInt()
        val out = ArrayList<Short>()
        for ((frequency, duration) in notes) {
            val count = (SAMPLE_RATE * duration).toInt()
            for (i in 0 until count) {
                if (frequency <= 0.0) {
                    out.add(0)
                    continue
                }
                val envelope = min(1.0, min(i, count - 1 - i).toDouble() / fade)
                val value = sin(2 * PI * frequency * i / SAMPLE_RATE) * 0.35 * envelope
                out.add((value * Short.MAX_VALUE).toInt().toShort())
            }
        }
        return out.toShortArray()
    }
}
