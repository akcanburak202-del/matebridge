package dev.matebridge.client.video

import java.util.Base64

/**
 * The capability self-test's clip (decision 0034, [FullChromaSelfTest]): ONE 4:2:0 HEVC Main intra frame, 256x144, Annex-B
 * (VPS, SPS, PPS, IDR slice), 5122 bytes, made once with VideoToolbox from a synthetic colour-block pattern (saturated blocks
 * and stripes, so every chroma sample differs from its neighbours). The test does not need to know the picture: it compares
 * the GPU's raw read of the decoded image with a CPU read of the same image.
 */
internal object FullChromaSelfTestClip {
    const val WIDTH = 256
    const val HEIGHT = 144

    private val BASE64 = listOf(
        "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",
        "bt/fjhq7fK2T2bzMdP0/M+KoJCaCgA==",
    )

    /** The Annex-B access unit. */
    val data: ByteArray by lazy { Base64.getDecoder().decode(BASE64.joinToString("")) }
}
