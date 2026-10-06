package dev.matebridge.client.video

import dev.matebridge.client.protocol.VideoFrame

/**
 * T-290: tests drain a [FrameQueue] through the production consumer path ([FrameQueue.awaitNext] as an owning
 * generation), not a test-only accessor, so ownership and catch-up marking are exercised the way the decoder uses them.
 */
internal const val TEST_CONSUMER = 1

/** The queue with [TEST_CONSUMER] as its owning generation (what the decoder's generation does at start). */
internal fun FrameQueue.ownedByTest(): FrameQueue = also { it.assignConsumer(TEST_CONSUMER) }

/** Next pending frame as the owning consumer, without waiting. */
internal fun FrameQueue.takeNow(): VideoFrame? = awaitNext(0, TEST_CONSUMER)
