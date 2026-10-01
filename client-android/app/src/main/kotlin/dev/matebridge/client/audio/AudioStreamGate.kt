package dev.matebridge.client.audio

import dev.matebridge.client.protocol.AudioConfig
import dev.matebridge.client.protocol.AudioFrame

/**
 * Which host audio stream is current (PROTOCOL.md 0x31/0x32), and for which control connection. Pure Kotlin; the
 * caller serializes [arm], [disarm] and [onConfig] (AudioPlayout's lock). [accepts] runs unlocked on the reader
 * thread, so the state it reads is volatile.
 *
 * Connection generation: [arm] (a new control connection) and [disarm] (connection closed, background) bound the
 * window in which messages are taken. A message from another generation, or while disarmed, is ignored: a stale
 * reader thread can neither start an orphan stream after teardown nor replace the new connection's stream.
 *
 *  - STARTED with a playable format (PCM_S16LE, 48 kHz, 2 channels) and a new stream_id: start it.
 *  - STARTED with anything else: the host's stream is not playable here; the current one stops (not an error).
 *  - STOPPED: stop. Unknown state: ignored.
 *  - AUDIO_FRAME: only the current stream's, and only when data_len = frame_count x channels x 2.
 */
class AudioStreamGate {
    sealed interface Action {
        data class Start(val streamId: Int) : Action
        data object Stop : Action
        data object Unsupported : Action
        data object None : Action
    }

    @Volatile var currentId = NONE
        private set

    @Volatile var armedGen = NONE
        private set

    val armed: Boolean get() = armedGen != NONE

    /** A new control connection [gen] starts: only its messages are taken from now on. Any running stream ends. */
    fun arm(gen: Int) {
        currentId = NONE
        armedGen = gen
    }

    /** The connection ended (or the app went to the background): nothing is taken until the next [arm]. */
    fun disarm() {
        currentId = NONE
        armedGen = NONE
    }

    fun onConfig(c: AudioConfig, gen: Int): Action {
        if (!armed || gen != armedGen) return Action.None
        return when (c.state) {
            AudioConfig.STATE_STOPPED -> if (currentId != NONE) { currentId = NONE; Action.Stop } else Action.None
            AudioConfig.STATE_STARTED -> when {
                !isPlayable(c) -> { currentId = NONE; Action.Unsupported }
                c.streamId == currentId -> Action.None // repeated STARTED of the running stream
                else -> { currentId = c.streamId; Action.Start(c.streamId) }
            }
            else -> Action.None
        }
    }

    fun accepts(f: AudioFrame, gen: Int): Boolean =
        gen == armedGen && currentId != NONE && f.streamId == currentId && f.data.size == f.frameCount * CHANNELS * 2

    companion object {
        const val NONE = -1
        const val SAMPLE_RATE = 48_000
        const val CHANNELS = 2

        fun isPlayable(c: AudioConfig): Boolean =
            c.format == AudioConfig.FORMAT_PCM_S16LE && c.sampleRate == SAMPLE_RATE.toLong() && c.channels == CHANNELS
    }
}
