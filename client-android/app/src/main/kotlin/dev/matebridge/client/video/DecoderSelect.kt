package dev.matebridge.client.video

import android.media.MediaCodec

/**
 * T-388 (dev knob `--es decoder <name>`): opens the main video decoder with `MediaCodec.createByCodecName` instead of
 * `createDecoderByType`. Any failure (name not a decoder for the MIME, create throws) falls back to [fallback], the
 * pre-T-388 path, and says why. Wraps the main decoder only: the auxiliary decoder and the full-chroma self test keep
 * using [MediaCodecDecoder.FACTORY].
 *
 * [byName] must throw for a name that cannot decode the MIME; the production one throws [Unsupported] for that.
 * [log] gets the level, the event (`decoder_select` / `decoder_fallback`) and its fields (codec names only).
 */
class NamedDecoderFactory(
    private val requested: String,
    private val byName: (name: String, mime: String) -> DecoderCodec,
    private val fallback: DecoderCodec.Factory,
    private val log: (level: Char, ev: String, fields: String) -> Unit,
) : DecoderCodec.Factory {
    class Unsupported(msg: String) : RuntimeException(msg)

    enum class Reason(val id: String) { MIME_UNSUPPORTED("mime_unsupported"), CREATE_FAILED("create_failed") }

    override fun create(mime: String): DecoderCodec {
        val codec = try {
            byName(requested, mime)
        } catch (e: Unsupported) {
            return fellBack(mime, Reason.MIME_UNSUPPORTED, e)
        } catch (e: Exception) {
            return fellBack(mime, Reason.CREATE_FAILED, e)
        }
        log('I', "decoder_select", "requested=$requested name=${codec.name} mime=$mime")
        return codec
    }

    private fun fellBack(mime: String, reason: Reason, e: Exception): DecoderCodec {
        log('W', "decoder_fallback", "requested=$requested mime=$mime reason=${reason.id} err=${e.javaClass.simpleName}")
        return fallback.create(mime)
    }

    companion object {
        /** Production: `createByCodecName`, released again when it is an encoder or does not list [mime]. */
        fun productionByName(name: String, mime: String): DecoderCodec {
            val c = MediaCodec.createByCodecName(name)
            val ok = try {
                !c.codecInfo.isEncoder && c.codecInfo.supportedTypes.any { it.equals(mime, ignoreCase = true) }
            } catch (e: Exception) { false }
            if (!ok) {
                try { c.release() } catch (_: Exception) {}
                throw Unsupported("not a decoder for the mime")
            }
            return MediaCodecDecoder.wrap(c)
        }

        /** Null when [name] is null (knob absent): the caller keeps its default factory. */
        fun forKnob(name: String?, fallback: DecoderCodec.Factory, log: (Char, String, String) -> Unit): DecoderCodec.Factory? =
            if (name == null) null else NamedDecoderFactory(name, ::productionByName, fallback, log)
    }
}
